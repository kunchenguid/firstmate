#!/usr/bin/env bash
# fm-devenv-install.test.sh - pinned remote runtime installation boundaries.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INSTALL="$ROOT/bin/fm-devenv-install.sh"
TMP_ROOT=$(fm_test_tmproot fm-devenv-install)
BASE_PATH=$PATH
REAL_GIT=$(command -v git)
export FM_TEST_REAL_GIT="$REAL_GIT"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

write_registry() {
  printf '%s\n' '[{"name":"alpha","vm":"expanly-alpha","slot":1,"frontend_port":5174,"branch":"feature/alpha"}]' > "$TMP_ROOT/registry.json"
}

make_fake_ssh() {
  local fakebin
  fakebin=$(fm_fakebin "$TMP_ROOT")
  cat > "$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
set -eu
call=1
if [ -f "$FM_TEST_SSH_LOG/calls" ]; then
  call=$(( $(cat "$FM_TEST_SSH_LOG/calls") + 1 ))
fi
printf '%s\n' "$call" > "$FM_TEST_SSH_LOG/calls"
mkdir -p "$FM_TEST_SSH_LOG/$call"
printf '%s\n' "$#" > "$FM_TEST_SSH_LOG/$call/argc"
printf '%s' "${1-}" > "$FM_TEST_SSH_LOG/$call/host"
printf '%s' "${2-}" > "$FM_TEST_SSH_LOG/$call/command"
cat > "$FM_TEST_SSH_LOG/$call/stdin"
HOME=$FM_TEST_REMOTE_HOME /bin/bash -c "${2-}" < "$FM_TEST_SSH_LOG/$call/stdin"
SH
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
set -eu
case "${1-}" in
  -Tf)
    rm -f -- "$3"
    /bin/mv "$2" "$3"
    ;;
  -f)
    if [ -L "$3" ] && [ -d "$3" ]; then
      /bin/mv "$2" "$3/"
    else
      /bin/mv "$2" "$3"
    fi
    ;;
  *) exec /bin/mv "$@" ;;
esac
SH
  chmod +x "$fakebin/ssh" "$fakebin/mv"
  printf '%s\n' "$fakebin"
}

make_racing_git() {  # <fakebin>
  local fakebin=$1
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
set -eu
if [ -n "${FM_TEST_SYMBOLIC_HEAD:-}" ] && [ "${1-}" = -C ] && [ "${3-}" = rev-parse ] && [ "${4-}" = HEAD ]; then
  cat "$FM_TEST_SYMBOLIC_HEAD"
  printf '%s\n' "$FM_TEST_NEXT_HEAD" > "$FM_TEST_SYMBOLIC_HEAD"
  exit 0
fi
if [ -n "${FM_TEST_SYMBOLIC_HEAD:-}" ] && [ "${1-}" = -C ] && [ "${3-}" = archive ]; then
  revision=$4
  [ "$revision" != HEAD ] || revision=$(cat "$FM_TEST_SYMBOLIC_HEAD")
  exec "$FM_TEST_REAL_GIT" -C "$2" archive "$revision" "${@:5}"
fi
exec "$FM_TEST_REAL_GIT" "$@"
SH
  chmod +x "$fakebin/git"
}

mode_of() {
  if stat -c '%a' "$1" >/dev/null 2>&1; then
    stat -c '%a' "$1"
  else
    stat -f '%Lp' "$1"
  fi
}

test_install_streams_only_the_pinned_tracked_runtime() {
  local fakebin commit input environment sent_commit manifest command release state
  mkdir -p "$TMP_ROOT/ssh-log" "$TMP_ROOT/remote-home"
  write_registry
  fakebin=$(make_fake_ssh)
  commit=$(git -C "$ROOT" rev-parse HEAD)

  FM_DEVENV_REGISTRY="$TMP_ROOT/registry.json" \
    FM_TEST_SSH_LOG="$TMP_ROOT/ssh-log" \
    FM_TEST_REMOTE_HOME="$TMP_ROOT/remote-home" \
    PATH="$fakebin:$BASE_PATH" \
    "$INSTALL" alpha

  [ "$(cat "$TMP_ROOT/ssh-log/1/argc")" = 2 ] \
    || fail "install did not invoke ssh with exactly a validated host and one fixed command"
  [ "$(cat "$TMP_ROOT/ssh-log/1/host")" = expanly-alpha ] \
    || fail "install did not use the VM returned by registry discovery"
  command=$(cat "$TMP_ROOT/ssh-log/1/command")
  assert_not_contains "$command" alpha "bootstrap command interpolated the environment"
  assert_not_contains "$command" "$commit" "bootstrap command interpolated the commit"

  input="$TMP_ROOT/ssh-log/1/stdin"
  IFS= read -r environment < "$input"
  IFS= read -r sent_commit < <(sed -n '2p' "$input")
  [ "$environment" = alpha ] || fail "install did not send the validated environment header"
  [ "$sent_commit" = "$commit" ] || fail "install did not send the current commit id"
  tail -n +3 "$input" | tar -tf - > "$TMP_ROOT/manifest"
  manifest=$(cat "$TMP_ROOT/manifest")
  assert_contains "$manifest" "AGENTS.md" "runtime archive omitted AGENTS.md"
  assert_contains "$manifest" "CLAUDE.md" "runtime archive omitted CLAUDE.md"
  assert_contains "$manifest" "bin/fm-devenv-lib.sh" "runtime archive omitted bin"
  assert_contains "$manifest" ".agents/skills/" "runtime archive omitted internal skills"
  assert_contains "$manifest" ".claude/skills" "runtime archive omitted the Claude skill link"
  assert_contains "$manifest" "skills/" "runtime archive omitted public skills"
  for private_path in .env config/ data/ state/ projects/ .git/; do
    ! grep -E "^${private_path}" "$TMP_ROOT/manifest" >/dev/null \
      || fail "runtime archive copied private path: $private_path"
  done

  release="$TMP_ROOT/remote-home/.local/share/firstmate-expanly/releases/$commit"
  state="$TMP_ROOT/remote-home/.local/state/firstmate-expanly/alpha"
  [ "$(cat "$release/.firstmate-runtime-commit")" = "$commit" ] \
    || fail "remote release marker did not record the pinned commit"
  [ "$(readlink "$TMP_ROOT/remote-home/.local/share/firstmate-expanly/current")" = "releases/$commit" ] \
    || fail "remote current link did not atomically select the pinned release"
  [ -d "$state" ] || fail "install did not create the environment state directory"
  [ "$(mode_of "$release")" = 700 ] || fail "release directory is not user-only writable"
  [ "$(mode_of "$state")" = 700 ] || fail "state directory is not user-only writable"
  [ ! -e "$release/.env" ] || fail "remote release contains local credentials"

  FM_DEVENV_REGISTRY="$TMP_ROOT/registry.json" \
    FM_TEST_SSH_LOG="$TMP_ROOT/ssh-log" \
    FM_TEST_REMOTE_HOME="$TMP_ROOT/remote-home" \
    PATH="$fakebin:$BASE_PATH" \
    "$INSTALL" alpha >/dev/null
  [ "$(cat "$TMP_ROOT/ssh-log/2/command")" = "$command" ] \
    || fail "bootstrap command changed between installations"
  [ "$(readlink "$TMP_ROOT/remote-home/.local/share/firstmate-expanly/current")" = "releases/$commit" ] \
    || fail "reinstall did not atomically replace the existing current link"
  [ -z "$(find "$release" -maxdepth 1 -name '.current.*' -print -quit)" ] \
    || fail "reinstall followed current and leaked its temporary selector into the release"
  pass "devenv install: streams one pinned tracked runtime without private state or credentials"
}

test_missing_environment_reports_usage() {
  local output rc
  output=$("$INSTALL" 2>&1)
  rc=$?
  expect_code 2 "$rc" "missing environment usage"
  assert_contains "$output" "usage: fm-devenv-install.sh" "missing environment did not print usage"
  pass "devenv install: missing environment reports the command contract"
}

test_archive_stays_bound_to_the_captured_commit() {
  local fakebin captured next release expected
  rm -rf "$TMP_ROOT/ssh-log" "$TMP_ROOT/remote-home"
  mkdir -p "$TMP_ROOT/ssh-log" "$TMP_ROOT/remote-home"
  write_registry
  fakebin=$(make_fake_ssh)
  make_racing_git "$fakebin"
  captured=$("$REAL_GIT" -C "$ROOT" rev-parse HEAD)
  next=$("$REAL_GIT" -C "$ROOT" rev-parse HEAD^)
  printf '%s\n' "$captured" > "$TMP_ROOT/symbolic-head"
  expected="$TMP_ROOT/expected-installer"
  "$REAL_GIT" -C "$ROOT" show "$captured:bin/fm-devenv-install.sh" > "$expected"

  FM_DEVENV_REGISTRY="$TMP_ROOT/registry.json" \
    FM_TEST_SSH_LOG="$TMP_ROOT/ssh-log" \
    FM_TEST_REMOTE_HOME="$TMP_ROOT/remote-home" \
    FM_TEST_SYMBOLIC_HEAD="$TMP_ROOT/symbolic-head" \
    FM_TEST_NEXT_HEAD="$next" \
    FM_TEST_REAL_GIT="$REAL_GIT" \
    PATH="$fakebin:$BASE_PATH" \
    "$INSTALL" alpha >/dev/null

  [ "$(cat "$TMP_ROOT/symbolic-head")" = "$next" ] \
    || fail "racing Git fixture did not change symbolic HEAD after commit capture"
  release="$TMP_ROOT/remote-home/.local/share/firstmate-expanly/releases/$captured"
  [ -f "$release/bin/fm-devenv-install.sh" ] \
    || fail "archive followed changed symbolic HEAD instead of the captured commit"
  cmp -s "$expected" "$release/bin/fm-devenv-install.sh" \
    || fail "archive bytes did not come from the captured commit"
  [ "$(cat "$release/.firstmate-runtime-commit")" = "$captured" ] \
    || fail "race fixture did not retain the captured commit marker"
  pass "devenv install: archive remains bound to the captured commit when symbolic HEAD changes"
}

test_unknown_environment_is_rejected_before_ssh() {
  local fakebin output rc
  rm -rf "$TMP_ROOT/ssh-log" "$TMP_ROOT/remote-home"
  mkdir -p "$TMP_ROOT/ssh-log" "$TMP_ROOT/remote-home"
  write_registry
  fakebin=$(make_fake_ssh)

  output=$(FM_DEVENV_REGISTRY="$TMP_ROOT/registry.json" \
    FM_TEST_SSH_LOG="$TMP_ROOT/ssh-log" \
    FM_TEST_REMOTE_HOME="$TMP_ROOT/remote-home" \
    PATH="$fakebin:$BASE_PATH" \
    "$INSTALL" missing 2>&1)
  rc=$?

  expect_code 1 "$rc" "unknown environment"
  assert_contains "$output" "unknown environment: missing" "unknown environment error was not precise"
  [ ! -e "$TMP_ROOT/ssh-log/calls" ] || fail "unknown environment reached ssh"
  pass "devenv install: rejects hosts absent from validated registry discovery before ssh"
}

test_verify_compares_only_and_never_repairs() {
  local fakebin commit marker current_target release_count output rc
  rm -rf "$TMP_ROOT/ssh-log" "$TMP_ROOT/remote-home"
  mkdir -p "$TMP_ROOT/ssh-log" "$TMP_ROOT/remote-home"
  write_registry
  fakebin=$(make_fake_ssh)
  commit=$(git -C "$ROOT" rev-parse HEAD)

  FM_DEVENV_REGISTRY="$TMP_ROOT/registry.json" \
    FM_TEST_SSH_LOG="$TMP_ROOT/ssh-log" \
    FM_TEST_REMOTE_HOME="$TMP_ROOT/remote-home" \
    PATH="$fakebin:$BASE_PATH" \
    "$INSTALL" alpha >/dev/null
  FM_DEVENV_REGISTRY="$TMP_ROOT/registry.json" \
    FM_TEST_SSH_LOG="$TMP_ROOT/ssh-log" \
    FM_TEST_REMOTE_HOME="$TMP_ROOT/remote-home" \
    PATH="$fakebin:$BASE_PATH" \
    "$INSTALL" --verify alpha >/dev/null \
    || fail "verify rejected the installed current commit"
  [ ! -s "$TMP_ROOT/ssh-log/2/stdin" ] || fail "verify streamed installation input"

  marker="$TMP_ROOT/remote-home/.local/share/firstmate-expanly/current/.firstmate-runtime-commit"
  printf '%s\n' stale-commit > "$marker"
  current_target=$(readlink "$TMP_ROOT/remote-home/.local/share/firstmate-expanly/current")
  release_count=$(find "$TMP_ROOT/remote-home/.local/share/firstmate-expanly/releases" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
  output=$(FM_DEVENV_REGISTRY="$TMP_ROOT/registry.json" \
    FM_TEST_SSH_LOG="$TMP_ROOT/ssh-log" \
    FM_TEST_REMOTE_HOME="$TMP_ROOT/remote-home" \
    PATH="$fakebin:$BASE_PATH" \
    "$INSTALL" --verify alpha 2>&1)
  rc=$?

  expect_code 1 "$rc" "mismatched remote commit"
  assert_contains "$output" "remote runtime mismatch" "verify mismatch was not precise"
  [ "$(cat "$marker")" = stale-commit ] || fail "verify repaired the remote marker"
  [ "$(readlink "$TMP_ROOT/remote-home/.local/share/firstmate-expanly/current")" = "$current_target" ] \
    || fail "verify replaced the remote current link"
  [ "$(find "$TMP_ROOT/remote-home/.local/share/firstmate-expanly/releases" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" = "$release_count" ] \
    || fail "verify created a release"
  [ ! -s "$TMP_ROOT/ssh-log/3/stdin" ] || fail "mismatched verify streamed installation input"
  pass "devenv install: verify compares the pinned marker without installing or repairing"
}

test_install_streams_only_the_pinned_tracked_runtime
test_missing_environment_reports_usage
test_archive_stays_bound_to_the_captured_commit
test_unknown_environment_is_rejected_before_ssh
test_verify_compares_only_and_never_repairs
