#!/usr/bin/env bash
# Behavior tests for the durable CLAUDE_CODE_OAUTH_TOKEN mechanism:
# bin/fm-oauth-token-load.sh (the login-time helper) and
# bin/fm-oauth-token-install.sh (the LaunchAgent installer), plus the committed
# plist template at bin/launchd/com.firstmate.oauth-token.plist.
#
# All tests are hermetic: launchctl and tmux are stubbed through a fakebin on
# PATH so no real launchd domain or tmux server is touched, and HOME /
# FM_CONFIG_OVERRIDE / FM_USER_LAUNCHAGENTS_DIR / FM_OAUTH_TOKEN_LOG_DIR point at
# temp dirs so no real captain file (in particular the real token) is read or
# written. The fake token values used here are inert strings, never a real
# credential.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-oauth-token)
HOME="$TMP_ROOT/home"
mkdir -p "$HOME"
export HOME

FAKE_TOKEN='fake-token-AAAA1234'

# make_fakebin: echo a fakebin dir with stubbed launchctl and tmux that record
# their calls into capture files under $1 and obey FM_FAKE_TOKEN_VALUE for
# `launchctl getenv`. Optional second arg "no-tmux" makes the tmux stub report
# no running server (tmux info exits 1).
make_fakebin() {
  local dir=$1 no_tmux=${2:-} fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/launchctl" <<SH
#!/usr/bin/env bash
set -u
cap="$dir/launchctl.calls"
case "\$1" in
  setenv)
    printf '%s|' "\$@" >> "\$cap"
    printf '\\n' >> "\$cap"
    exit 0
    ;;
  getenv)
    # FM_FAKE_TOKEN_VALUE controls presence; print it on stdout (the helper
    # pipes launchctl getenv output into grep -q .) and exit 0 only when set.
    if [ -n "\${FM_FAKE_TOKEN_VALUE:-}" ]; then
      printf '%s\\n' "\${FM_FAKE_TOKEN_VALUE:-}"
      exit 0
    fi
    exit 1
    ;;
  load)
    printf '%s|' "\$@" >> "\$cap"
    printf '\\n' >> "\$cap"
    exit 0
    ;;
  unload)
    printf '%s|' "\$@" >> "\$cap"
    printf '\\n' >> "\$cap"
    exit 0
    ;;
  remove)
    printf '%s|' "\$@" >> "\$cap"
    printf '\\n' >> "\$cap"
    exit 0
    ;;
  unsetenv)
    printf '%s|' "\$@" >> "\$cap"
    printf '\\n' >> "\$cap"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/launchctl"
  if [ "$no_tmux" = "no-tmux" ]; then
    cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
  info) exit 1 ;;   # no running tmux server
  *) exit 0 ;;
esac
SH
  else
    cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
case "\$1" in
  info) exit 0 ;;
  set-environment)
    printf '%s|' "\$@" >> "$dir/tmux.calls"
    printf '\\n' >> "$dir/tmux.calls"
    exit 0
    ;;
esac
exit 0
SH
  fi
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

# token_file <value>: echo path to a temp token file containing <value>.
token_file() {
  local f
  f="$TMP_ROOT/token-$(printf '%s' "$1" | cksum | cut -d' ' -f1)"
  printf '%s' "$1" > "$f"
  chmod 600 "$f"
  printf '%s\n' "$f"
}

run_load() {
  FM_OAUTH_TOKEN_FILE="${FM_OAUTH_TOKEN_FILE:-}" \
    FM_CONFIG_OVERRIDE="${FM_CONFIG_OVERRIDE:-$TMP_ROOT/config}" \
    PATH="$1:$PATH" \
    "$ROOT/bin/fm-oauth-token-load.sh" "${@:2}"
}

# --- helper: --setenv calls launchctl and tmux, never prints the value -------

test_setenv_calls_launchctl_and_tmux() {
  local fakebin tf out cap
  fakebin=$(make_fakebin "$TMP_ROOT/fb1")
  tf=$(token_file "$FAKE_TOKEN")
  out=$(FM_OAUTH_TOKEN_FILE="$tf" run_load "$fakebin" --setenv 2>&1)
  assert_contains "$out" "oauth-token: set CLAUDE_CODE_OAUTH_TOKEN in the launchd user domain" \
    "--setenv did not report success"
  assert_not_contains "$out" "$FAKE_TOKEN" \
    "--setenv leaked the token value to stdout/stderr"
  cap=$(cat "$TMP_ROOT/fb1/launchctl.calls")
  assert_contains "$cap" "setenv|CLAUDE_CODE_OAUTH_TOKEN|$FAKE_TOKEN|" \
    "launchctl setenv was not called with the label and token value"
  assert_contains "$(cat "$TMP_ROOT/fb1/tmux.calls")" "set-environment|-g|CLAUDE_CODE_OAUTH_TOKEN|$FAKE_TOKEN|" \
    "tmux set-environment -g was not called with the token when a server was reachable"
  pass "fm-oauth-token-load --setenv: calls launchctl setenv and tmux set-environment, never prints the token"
}

test_setenv_skips_tmux_when_no_server() {
  local fakebin tf out
  fakebin=$(make_fakebin "$TMP_ROOT/fb2" no-tmux)
  tf=$(token_file "$FAKE_TOKEN")
  out=$(FM_OAUTH_TOKEN_FILE="$tf" run_load "$fakebin" --setenv 2>&1)
  assert_contains "$out" "oauth-token: set CLAUDE_CODE_OAUTH_TOKEN in the launchd user domain" \
    "--setenv failed despite no tmux server"
  assert_contains "$(cat "$TMP_ROOT/fb2/launchctl.calls")" "setenv|CLAUDE_CODE_OAUTH_TOKEN|" \
    "launchctl setenv was skipped when tmux was unavailable"
  [ ! -f "$TMP_ROOT/fb2/tmux.calls" ] || fail "tmux set-environment was called despite no server"
  pass "fm-oauth-token-load --setenv: still sets launchctl when no tmux server is reachable, and skips tmux"
}

# --- helper: --export and --print --------------------------------------------

test_export_quotes_value() {
  local fakebin tf out
  fakebin=$(make_fakebin "$TMP_ROOT/fb3")
  tf=$(token_file "$FAKE_TOKEN")
  out=$(FM_OAUTH_TOKEN_FILE="$tf" run_load "$fakebin" --export 2>/dev/null)
  [ "$out" = "export CLAUDE_CODE_OAUTH_TOKEN='$FAKE_TOKEN'" ] \
    || fail "--export did not produce the expected single-quoted export line: '$out'"
  # a value containing a single quote must be escaped with the '\'' idiom
  tf=$(token_file "a'b")
  out=$(FM_OAUTH_TOKEN_FILE="$tf" run_load "$fakebin" --export 2>/dev/null)
  [ "$out" = "export CLAUDE_CODE_OAUTH_TOKEN='a'\''b'" ] \
    || fail "--export did not escape an embedded single quote: '$out'"
  pass "fm-oauth-token-load --export: emits a shell-safe export line and escapes embedded single quotes"
}

test_print_value() {
  local fakebin tf out
  fakebin=$(make_fakebin "$TMP_ROOT/fb4")
  tf=$(token_file "$FAKE_TOKEN")
  out=$(FM_OAUTH_TOKEN_FILE="$tf" run_load "$fakebin" --print 2>/dev/null)
  [ "$out" = "$FAKE_TOKEN" ] || fail "--print did not print exactly the token value: '$out'"
  pass "fm-oauth-token-load --print: prints the resolved token value"
}

# --- helper: source resolution and error paths -------------------------------

test_missing_source_errors_without_leaking() {
  local fakebin out rc
  fakebin=$(make_fakebin "$TMP_ROOT/fb5")
  out=$(FM_OAUTH_TOKEN_FILE='' run_load "$fakebin" --print 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "--print with no resolvable source exited 0"
  assert_contains "$out" "no token file" \
    "--print did not explain the missing token file"
  assert_not_contains "$out" "$FAKE_TOKEN" \
    "--print leaked a token while reporting a missing source"
  pass "fm-oauth-token-load: a missing secure source errors clearly and never leaks a token"
}

test_cmd_source_runs_command() {
  local fakebin cfg out
  fakebin=$(make_fakebin "$TMP_ROOT/fb6")
  cfg="$TMP_ROOT/config"
  mkdir -p "$cfg"
  printf 'cmd:printf %%s cmd-token-XYZ\n' > "$cfg/oauth-token-source"
  out=$(FM_OAUTH_TOKEN_FILE='' FM_CONFIG_OVERRIDE="$cfg" run_load "$fakebin" --print 2>/dev/null)
  [ "$out" = "cmd-token-XYZ" ] || fail "cmd: source did not resolve to the command's stdout: '$out'"
  pass "fm-oauth-token-load: config/oauth-token-source cmd: prefix runs the command and uses its stdout"
}

test_op_source_uses_op_cli() {
  local fakebin cfg out
  fakebin=$(make_fakebin "$TMP_ROOT/fb7")
  local refcap="$TMP_ROOT/fb7/op.ref"
  # op stub captures the reference it received and only succeeds for a full
  # op:// reference, so a scheme-stripped ref (the old bug) would fail.
  cat > "$fakebin/op" <<SH
#!/usr/bin/env bash
case "\$1" in
  read)
    printf '%s' "\$2" > "$refcap"
    case "\$2" in
      op://*) printf '%s' 'op-token-789' ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/op"
  cfg="$TMP_ROOT/config"
  mkdir -p "$cfg"
  printf 'op://Private/firstmate/claude/token\n' > "$cfg/oauth-token-source"
  out=$(FM_OAUTH_TOKEN_FILE='' FM_CONFIG_OVERRIDE="$cfg" run_load "$fakebin" --print 2>/dev/null)
  [ "$out" = "op-token-789" ] || fail "op:// source did not resolve via the op CLI: '$out'"
  [ "$(cat "$refcap")" = "op://Private/firstmate/claude/token" ] \
    || fail "op read received a mangled reference: '$(cat "$refcap")'"
  pass "fm-oauth-token-load: config/oauth-token-source op:// reference resolves via op read with the full reference intact"
}

test_loose_perms_warn_but_proceed() {
  local fakebin tf out err
  fakebin=$(make_fakebin "$TMP_ROOT/fb8")
  tf="$TMP_ROOT/loose-token"
  printf '%s' "$FAKE_TOKEN" > "$tf"
  chmod 644 "$tf"
  err=$(FM_OAUTH_TOKEN_FILE="$tf" run_load "$fakebin" --print 2>&1 1>/dev/null)
  assert_contains "$err" "warn: token file" "loose perms did not produce a warning"
  assert_contains "$err" "expected 600" "loose-perms warning did not name the expected mode"
  out=$(FM_OAUTH_TOKEN_FILE="$tf" run_load "$fakebin" --print 2>/dev/null)
  [ "$out" = "$FAKE_TOKEN" ] || fail "loose perms prevented the token from being read"
  pass "fm-oauth-token-load: a world/loose-perm token file warns but still resolves the token"
}

# --- helper: --check reads the launchd domain, not the source ----------------

test_check_present_and_absent() {
  local fakebin out rc
  fakebin=$(make_fakebin "$TMP_ROOT/fb9")
  # FM_FAKE_TOKEN_VALUE must be exported so the stubbed launchctl subprocess
  # (a child of the helper) actually sees it.
  export FM_FAKE_TOKEN_VALUE='whatever'
  out=$(run_load "$fakebin" --check 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] || fail "--check exited non-zero when the var was present"
  assert_contains "$out" "present in the launchd user domain" "--check present wording missing"
  FM_FAKE_TOKEN_VALUE=''
  out=$(run_load "$fakebin" --check 2>/dev/null); rc=$?
  [ "$rc" -ne 0 ] || fail "--check exited 0 when the var was absent"
  assert_contains "$out" "absent from the launchd user domain" "--check absent wording missing"
  unset FM_FAKE_TOKEN_VALUE
  pass "fm-oauth-token-load --check: reports presence/absence from the launchd domain"
}

# --- plist template: placeholders, no token ----------------------------------

test_template_shape() {
  local t="$ROOT/bin/launchd/com.firstmate.oauth-token.plist"
  assert_present "$t" "plist template missing"
  assert_grep "@@FM_BIN@@" "$t" "template missing the @@FM_BIN@@ placeholder"
  assert_grep "@@FM_LOG_DIR@@" "$t" "template missing the @@FM_LOG_DIR@@ placeholder"
  assert_grep "fm-oauth-token-load.sh" "$t" "template does not reference the helper"
  assert_grep "--setenv" "$t" "template does not pass --setenv to the helper"
  assert_grep "<true/>" "$t" "template is not set to run at load (RunAtLoad true)"
  # a path-shaped secret like an sk- token must never be committed in the template
  assert_no_grep "sk-" "$t" "template contains an sk- shaped literal"
  pass "plist template: references the helper via placeholders, runs --setenv at load, and carries no token"
}

# --- installer: render, load, idempotent, uninstall --------------------------

# run_install <fakebin> <args...>: invoke the installer with the fakebin on PATH
# and the per-test FM_USER_LAUNCHAGENTS_DIR / FM_OAUTH_TOKEN_LOG_DIR already in
# the environment (set by each caller).
run_install() {
  PATH="$1:$PATH" \
    "$ROOT/bin/fm-oauth-token-install.sh" "${@:2}"
}

test_install_renders_and_loads() {
  local fakebin tf agents_dir target out cap
  fakebin=$(make_fakebin "$TMP_ROOT/fb10")
  tf=$(token_file "$FAKE_TOKEN")
  agents_dir="$TMP_ROOT/LaunchAgents"
  target="$agents_dir/com.firstmate.oauth-token.plist"
  out=$(FM_OAUTH_TOKEN_FILE="$tf" \
    FM_USER_LAUNCHAGENTS_DIR="$agents_dir" \
    FM_OAUTH_TOKEN_LOG_DIR="$TMP_ROOT/logs" \
    run_install "$fakebin" --install 2>&1)
  assert_contains "$out" "installed and loaded" "install did not report loaded"
  assert_present "$target" "install did not write the plist to the agents dir"
  assert_no_grep "@@FM_BIN@@" "$target" "rendered plist still has an unsubstituted @@FM_BIN@@"
  assert_no_grep "@@FM_LOG_DIR@@" "$target" "rendered plist still has an unsubstituted @@FM_LOG_DIR@@"
  assert_grep "$ROOT/bin/fm-oauth-token-load.sh" "$target" "rendered plist does not reference the real helper path"
  assert_grep "oauth-token.err.log" "$target" "rendered plist does not reference the per-user log path"
  cap=$(cat "$TMP_ROOT/fb10/launchctl.calls")
  assert_contains "$cap" "load|-w|$target|" "launchctl load -w was not called with the rendered plist"
  assert_not_contains "$out" "$FAKE_TOKEN" "install leaked the token value"
  pass "fm-oauth-token-install --install: renders the template, loads it, and never emits the token"
}

test_install_idempotent() {
  local fakebin tf agents_dir target a b
  fakebin=$(make_fakebin "$TMP_ROOT/fb11")
  tf=$(token_file "$FAKE_TOKEN")
  agents_dir="$TMP_ROOT/LaunchAgents-idem"
  target="$agents_dir/com.firstmate.oauth-token.plist"
  FM_OAUTH_TOKEN_FILE="$tf" \
    FM_USER_LAUNCHAGENTS_DIR="$agents_dir" \
    FM_OAUTH_TOKEN_LOG_DIR="$TMP_ROOT/logs-idem" \
    run_install "$fakebin" --install >/dev/null 2>&1
  a=$(cat "$target")
  # second install should unload the prior copy first, then rewrite and reload
  : > "$TMP_ROOT/fb11/launchctl.calls"
  FM_OAUTH_TOKEN_FILE="$tf" \
    FM_USER_LAUNCHAGENTS_DIR="$agents_dir" \
    FM_OAUTH_TOKEN_LOG_DIR="$TMP_ROOT/logs-idem" \
    run_install "$fakebin" --install >/dev/null 2>&1
  b=$(cat "$target")
  [ "$a" = "$b" ] || fail "second install produced a different plist (not idempotent)"
  assert_contains "$(cat "$TMP_ROOT/fb11/launchctl.calls")" "unload|" \
    "second install did not unload the prior copy before reloading"
  pass "fm-oauth-token-install --install: is idempotent (unload-then-reload, byte-identical plist)"
}

test_uninstall_removes_plist_and_unsetenv() {
  local fakebin tf agents_dir target out cap
  fakebin=$(make_fakebin "$TMP_ROOT/fb12")
  tf=$(token_file "$FAKE_TOKEN")
  agents_dir="$TMP_ROOT/LaunchAgents-un"
  target="$agents_dir/com.firstmate.oauth-token.plist"
  FM_OAUTH_TOKEN_FILE="$tf" \
    FM_USER_LAUNCHAGENTS_DIR="$agents_dir" \
    FM_OAUTH_TOKEN_LOG_DIR="$TMP_ROOT/logs-un" \
    run_install "$fakebin" --install >/dev/null 2>&1
  out=$(FM_OAUTH_TOKEN_FILE="$tf" \
    FM_USER_LAUNCHAGENTS_DIR="$agents_dir" \
    FM_OAUTH_TOKEN_LOG_DIR="$TMP_ROOT/logs-un" \
    run_install "$fakebin" --uninstall 2>&1)
  assert_absent "$target" "uninstall did not remove the plist"
  assert_contains "$out" "removed" "uninstall did not report removal"
  cap=$(cat "$TMP_ROOT/fb12/launchctl.calls")
  assert_contains "$cap" "unload|-w|$target|" "uninstall did not unload the agent"
  assert_contains "$cap" "unsetenv|CLAUDE_CODE_OAUTH_TOKEN" "uninstall did not unsetenv the token"
  pass "fm-oauth-token-install --uninstall: unloads, removes the plist, and unsetenvs the token"
}

test_install_refuses_without_launchctl() {
  local out rc empty
  # Pointing FM_LAUNCHCTL at a name that is not on PATH exercises the
  # require_launchctl refusal without removing /usr/bin (which also holds
  # dirname/cat/grep) from PATH - so the script still starts and resolves its
  # own dir. Works identically on macOS and Linux CI.
  empty=$(fm_fakebin "$TMP_ROOT/no-launch")
  out=$(FM_USER_LAUNCHAGENTS_DIR="$TMP_ROOT/LaunchAgents-nolaunch" \
    FM_OAUTH_TOKEN_LOG_DIR="$TMP_ROOT/logs-nolaunch" \
    FM_OAUTH_TOKEN_FILE="$(token_file "$FAKE_TOKEN")" \
    FM_LAUNCHCTL='launchctl-not-on-path' \
    PATH="$empty:/usr/bin:/bin" \
    bash "$ROOT/bin/fm-oauth-token-install.sh" --install 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "install exited 0 without launchctl on PATH"
  assert_contains "$out" "launchctl not found" "install did not explain the missing launchctl"
  pass "fm-oauth-token-install: refuses with a clear error when launchctl is unavailable"
}

test_setenv_calls_launchctl_and_tmux
test_setenv_skips_tmux_when_no_server
test_export_quotes_value
test_print_value
test_missing_source_errors_without_leaking
test_cmd_source_runs_command
test_op_source_uses_op_cli
test_loose_perms_warn_but_proceed
test_check_present_and_absent
test_template_shape
test_install_renders_and_loads
test_install_idempotent
test_uninstall_removes_plist_and_unsetenv
test_install_refuses_without_launchctl
