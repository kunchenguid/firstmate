#!/usr/bin/env bash
# Portable contract test for the remote secondmate control transport.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-remote-secondmate-control)
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)

make_fixture() {
  local dir=$1 remote_root=$1/remote-root target_home=$1/target-home
  mkdir -p "$remote_root/bin" "$remote_root/state/parent-route" "$target_home/bin" "$target_home/state/parent-route" \
    "$target_home/data/.parent-route" "$target_home/config"
  printf '%s\n' ios > "$target_home/.fm-secondmate-home"
  : > "$target_home/AGENTS.md"

  cp "$ROOT/bin/fm-remote-secondmate-control.sh" "$remote_root/bin/"
  cat > "$remote_root/bin/fm-backend.sh" <<'SH'
#!/usr/bin/env bash
fm_backend_validate_task_endpoint() {
  FM_BACKEND_VALIDATED_BACKEND=herdr
  FM_BACKEND_VALIDATED_TARGET='fm-remote:?pane'
  return 0
}
fm_backend_agent_state() { printf 'alive\n'; }
fm_backend_kill() { return 0; }
fm_backend_meta_exact_value() { sed -n "s/^$2=//p" "$1" | head -1; }
fm_meta_get() { sed -n "s/^$2=//p" "$1" | head -1; }
SH
  cat > "$remote_root/bin/fm-ff-lib.sh" <<'SH'
#!/usr/bin/env bash
SH
  cat > "$remote_root/bin/fm-pending-reply-lib.sh" <<'SH'
#!/usr/bin/env bash
SH
  cat > "$remote_root/bin/fm-task-inbox-lib.sh" <<'SH'
#!/usr/bin/env bash
SH
  cat > "$remote_root/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
set -u
id=$1
harness=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --harness)
      shift
      harness=${1:-}
      ;;
  esac
  shift || break
done
mkdir -p "$FM_STATE_OVERRIDE"
{
  printf 'backend=herdr\n'
  printf 'window=fm-remote:?pane\n'
  printf 'endpoint_task_id=%s\n' "$id"
  printf 'herdr_session=fm-remote\n'
  printf 'harness=%s\n' "$harness"
} > "$FM_STATE_OVERRIDE/$id.meta"
SH
  cat > "$remote_root/bin/fm-control.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" > "$FM_HOME/state/parent-route/control.args"
SH
  chmod +x "$remote_root/bin/fm-remote-secondmate-control.sh" "$remote_root/bin/fm-backend.sh" \
    "$remote_root/bin/fm-ff-lib.sh" "$remote_root/bin/fm-pending-reply-lib.sh" \
    "$remote_root/bin/fm-task-inbox-lib.sh" "$remote_root/bin/fm-spawn.sh" \
    "$remote_root/bin/fm-control.sh"

  printf '%s\n' "$remote_root|$target_home"
}

test_copilot_launch_and_relaunch_share_verified_remote_set() {
  local rec dir remote_root target_home out rc
  rec=$(make_fixture "$TMP_ROOT/copilot-remote")
  IFS='|' read -r remote_root target_home <<EOF
$rec
EOF

  out=$(FM_HOME="$target_home" FM_ROOT_OVERRIDE="$remote_root" \
    "$remote_root/bin/fm-remote-secondmate-control.sh" launch ios copilot - - herdr)
  rc=$?
  expect_code 0 "$rc" "Copilot remote secondmate launch should use the verified harness allowlist"
  assert_contains "$out" 'harness=copilot' "remote launch did not preserve the Copilot harness"
  assert_present "$target_home/state/parent-route/ios.meta" "remote launch did not publish endpoint metadata"

  out=$(FM_HOME="$target_home" FM_ROOT_OVERRIDE="$remote_root" \
    "$remote_root/bin/fm-remote-secondmate-control.sh" relaunch ios copilot - -)
  rc=$?
  expect_code 0 "$rc" "Copilot remote secondmate relaunch should use the same verified harness allowlist"
  [ "$(cat "$remote_root/state/parent-route/control.args")" = 'ios relaunch --harness copilot --model default --effort default' ] \
    || fail "remote relaunch did not forward the Copilot harness through the ordinary control plane"
  pass "remote secondmate control keeps Copilot on the same verified launch and relaunch set"
}

test_copilot_launch_and_relaunch_share_verified_remote_set

echo "# all fm-remote-secondmate-control tests passed"
