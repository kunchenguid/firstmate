#!/usr/bin/env bash
# Behavioral coverage for model-catalog primary-to-secondmate convergence,
# exact CONFIG_REREAD delivery, absence, invalid-source rejection, retry, and
# remote allowlist publication.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

JQ_BIN_DIR=
if command -v jq >/dev/null 2>&1; then
  JQ_BIN_DIR="$(dirname "$(command -v jq)"):"
fi
BASE_PATH=${FM_TEST_BASE_PATH:-${JQ_BIN_DIR}/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-model-catalog-inheritance)
CONFIG_PUSH="$ROOT/bin/fm-config-push.sh"

# shellcheck source=bin/fm-config-inherit-lib.sh disable=SC1091
. "$ROOT/bin/fm-config-inherit-lib.sh"

valid_catalog_v1() {
  cat <<'EOF'
{
  "pools": [
    {
      "pool": "kimi",
      "provider": "moonshot",
      "plan": "kimi-code",
      "harness": "kimi",
      "account": "kimi-code-cli",
      "models": ["kimi-code/k3"],
      "quota_readable": false
    }
  ]
}
EOF
}

valid_catalog_v2() {
  cat <<'EOF'
{
  "pools": [
    {
      "pool": "kimi",
      "provider": "moonshot",
      "plan": "kimi-code",
      "harness": "kimi",
      "account": "kimi-code-cli",
      "models": ["kimi-code/k3", "kimi-code/k3-256k", "kimi-code/k2.7-coding"],
      "quota_readable": false
    }
  ]
}
EOF
}

pool_model_count() {
  local path=$1
  jq -r '.pools[0].models | length' "$path" 2>/dev/null || printf '0\n'
}

make_fake_toolchain() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FAKE_TMUX_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
case "$*" in
  *display-message*'#{pane_current_command}'*) printf '%s\n' codex; exit 0 ;;
  *display-message*'#{pane_id}'*) printf '%s\n' '%1'; exit 0 ;;
  *display-message*'#{cursor_y}'*) printf '%s\n' 0; exit 0 ;;
  *capture-pane*) printf '\n'; exit 0 ;;
  *'send-keys'*' -l '*)
    [ "${FM_FAKE_TMUX_FAIL_LITERAL:-0}" = 1 ] && exit 1
    exit 0
    ;;
  *send-keys*)
    [ "${FM_FAKE_TMUX_FAIL_LITERAL:-0}" = 1 ] && exit 1
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

new_propagation_world() {
  local name=$1 world root home sm head
  world="$TMP_ROOT/$name"
  root="$world/root"
  home="$world/home"
  sm="$world/sm"
  mkdir -p "$home/config" "$home/data" "$home/state" "$root/bin"
  touch "$home/state/.last-watcher-beat"
  git init -q -b main "$root"
  printf '%s\n' 'config/' > "$root/.gitignore"
  printf '%s\n' '# Firstmate test root' > "$root/AGENTS.md"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$root/bin/placeholder.sh"
  chmod +x "$root/bin/placeholder.sh"
  git -C "$root" add -A
  git -C "$root" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -qm initial
  head=$(git -C "$root" rev-parse HEAD)
  git -C "$root" worktree add -q --detach "$sm" "$head"
  printf '%s\n' sm > "$sm/.fm-secondmate-home"
  mkdir -p "$sm/config" "$sm/data" "$sm/state" "$sm/projects"
  {
    printf 'window=firstmate:fm-sm\n'
    printf 'kind=secondmate\n'
    printf 'harness=codex\n'
    printf 'home=%s\n' "$sm"
  } > "$home/state/sm.meta"
  mkdir "$home/state/.watch.lock"
  printf '%s\n' "$$" > "$home/state/.watch.lock/pid"
  printf '%s\n' "$home" > "$home/state/.watch.lock/fm-home"
  printf '%s\n' "$ROOT/bin/fm-watch.sh" > "$home/state/.watch.lock/watcher-path"
  identity=$(FM_STATE_OVERRIDE="$home/state" bash -c '. "$1"; fm_pid_identity "$2"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$$") || fail "could not identify the live watcher fixture"
  printf '%s\n' "$identity" > "$home/state/.watch.lock/pid-identity"
  printf '%s\n' "$root|$home|$sm"
}

latest_reread_instruction() {
  local home=$1 state path latest=
  state=$(cd "$home/state" && pwd -P) || return 1
  for path in "$state"/.fm-inherited-config-reread.*; do
    case "$path" in *.pending) continue ;; esac
    [ -f "$path" ] && [ ! -L "$path" ] || continue
    latest=$path
  done
  [ -n "$latest" ] || return 1
  printf '%s\n' "$latest"
}

inbox_stream() {  # <parent-state-dir> <task-id>
  local rec
  for rec in "$1/$2.inbox"/*.msg; do
    [ -e "$rec" ] || continue
    bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$rec"
    printf '\n'
  done
}

run_config_push() {
  local root=$1 home=$2 fakebin=$3 log=$4
  touch "$home/state/.last-watcher-beat"
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" FM_SEND_SETTLE=0 \
    FM_FAKE_TMUX_LOG="$log" "$CONFIG_PUSH"
}

catalog_converges_with_reread_before_intake() {
  local rec root home sm fakebin log out instruction inbox_message v1_count v2_count reread_line intake_line
  rec=$(new_propagation_world local-catalog)
  root=${rec%%|*}
  rec=${rec#*|}
  home=${rec%%|*}
  sm=${rec#*|}
  fakebin=$(make_fake_toolchain "$TMP_ROOT/local-catalog")
  log="$TMP_ROOT/local-catalog.tmux.log"

  printf '%s' "$(valid_catalog_v1)" > "$home/config/model-catalog.json"
  out=$(run_config_push "$root" "$home" "$fakebin" "$log")
  assert_contains "$out" 'model-catalog.json: pushed' \
    "config push did not report model-catalog as pushed"
  v1_count=$(pool_model_count "$sm/config/model-catalog.json")
  [ "$v1_count" = 1 ] || fail "secondmate did not receive the first catalog generation ($v1_count models)"
  instruction=$(latest_reread_instruction "$sm") || fail "catalog propagation did not publish a reread instruction"
  assert_contains "$(cat "$instruction")" 'config/model-catalog.json' \
    "reread instruction must name the catalog path"
  assert_contains "$(cat "$instruction")" 'kimi-code/k3' \
    "reread instruction must carry converged catalog content"
  inbox_message=$(find "$home/state/sm.inbox" -maxdepth 1 -type f -name '*.msg' -print | LC_ALL=C sort | tail -1)
  [ -n "$inbox_message" ] || fail "catalog propagation did not enqueue its reread pointer"
  assert_contains "$(cat "$inbox_message")" "CONFIG_REREAD: $instruction" \
    "catalog propagation must enqueue the exact reread pointer"

  printf '%s' "$(valid_catalog_v2)" > "$home/config/model-catalog.json"
  out=$(run_config_push "$root" "$home" "$fakebin" "$log")
  assert_contains "$out" 'model-catalog.json: pushed' \
    "content-change push did not report model-catalog as pushed"
  assert_contains "$out" 'config-reread: sent' \
    "content-change push must send a reread notification"
  v2_count=$(pool_model_count "$sm/config/model-catalog.json")
  [ "$v2_count" = 3 ] || fail "secondmate did not receive the updated catalog generation ($v2_count models)"
  instruction=$(latest_reread_instruction "$sm") || fail "content-change push did not publish a reread instruction"
  assert_contains "$(cat "$instruction")" 'k3-256k' \
    "content-change reread must include the new model variant"
  assert_contains "$(inbox_stream "$home/state" sm)" "CONFIG_REREAD: $instruction" \
    "content-change must notify after destination bytes settle"
  printf '%s\n' 'TASK_INTAKE: local-catalog' >> "$log"
  reread_line=$(grep -nF 'Firstmate instruction waiting: list ' "$log" | tail -1 | cut -d: -f1)
  intake_line=$(grep -nF 'TASK_INTAKE: local-catalog' "$log" | tail -1 | cut -d: -f1)
  [ "$reread_line" -lt "$intake_line" ] \
    || fail "local catalog reread notification did not precede later task intake"

  rm -f "$home/config/model-catalog.json"
  out=$(run_config_push "$root" "$home" "$fakebin" "$log")
  assert_contains "$out" 'model-catalog.json: pushed - mirrored primary absence' \
    "primary absence must converge downstream"
  [ ! -e "$sm/config/model-catalog.json" ] \
    || fail "primary absence did not remove the inherited catalog"
  instruction=$(latest_reread_instruction "$sm") || fail "absence push did not publish a reread instruction"
  assert_contains "$(cat "$instruction")" $'-----BEGIN config/model-catalog.json-----\nABSENT\n-----END config/model-catalog.json-----' \
    "absence reread must use the explicit ABSENT payload"

  pass "local secondmate receives catalog generations with settle-then-notify ordering"
}

invalid_catalog_is_quarantined_at_publication() {
  local rec root home sm sm2 fakebin log out stale_count quarantine head rc
  rec=$(new_propagation_world invalid-catalog)
  root=${rec%%|*}
  rec=${rec#*|}
  home=${rec%%|*}
  sm=${rec#*|}
  fakebin=$(make_fake_toolchain "$TMP_ROOT/invalid-catalog")
  log="$TMP_ROOT/invalid-catalog.tmux.log"
  sm2="$TMP_ROOT/invalid-catalog/sm2"
  head=$(git -C "$root" rev-parse HEAD)
  git -C "$root" worktree add -q --detach "$sm2" "$head"
  printf '%s\n' sm2 > "$sm2/.fm-secondmate-home"
  mkdir -p "$sm2/config" "$sm2/data" "$sm2/state" "$sm2/projects"
  {
    printf 'window=firstmate:fm-sm2\n'
    printf 'kind=secondmate\n'
    printf 'harness=codex\n'
    printf 'home=%s\n' "$sm2"
  } > "$home/state/sm2.meta"

  printf '%s' "$(valid_catalog_v1)" > "$home/config/model-catalog.json"
  run_config_push "$root" "$home" "$fakebin" "$log" >/dev/null

  printf '{"pools":[]}' > "$home/config/model-catalog.json"
  printf '%s\n' codex > "$home/config/backend"
  set +e
  out=$(run_config_push "$root" "$home" "$fakebin" "$log" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "invalid primary catalog should stop propagation"
  assert_contains "$out" 'model-catalog.json: error' \
    "invalid catalog must report a propagation error"
  stale_count=$(pool_model_count "$sm/config/model-catalog.json")
  [ "$stale_count" = 1 ] || fail "invalid primary catalog overwrote the converged destination ($stale_count models)"
  stale_count=$(pool_model_count "$sm2/config/model-catalog.json")
  [ "$stale_count" = 1 ] \
    || fail "invalid primary catalog converged to absence in a later destination ($stale_count models)"
  [ "$(cat "$sm/config/backend")" = codex ] && [ "$(cat "$sm2/config/backend")" = codex ] \
    || fail "invalid model catalog blocked unrelated inherited config convergence"
  assert_contains "$out" 'backend: pushed' \
    "invalid model catalog did not report unrelated config convergence"
  [ ! -e "$home/config/model-catalog.json" ] || fail "invalid primary catalog remained at its publication path"
  quarantine=$(find "$home/config" -maxdepth 1 -type f -name 'model-catalog.json.invalid-*' -print | head -1)
  [ -n "$quarantine" ] || fail "invalid primary catalog was not quarantined"
  [ "$(jq -r '.pools | length' "$quarantine")" = 0 ] \
    || fail "quarantine did not preserve the invalid primary artifact"
  assert_present "$home/config/.model-catalog.invalid-primary" \
    "invalid primary quarantine did not leave durable invalid-source state"

  set +e
  out=$(run_config_push "$root" "$home" "$fakebin" "$log" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "quarantined primary catalog should block a later convergence sweep"
  assert_contains "$out" 'remains quarantined' \
    "later convergence did not distinguish quarantine from intentional absence"
  [ "$(pool_model_count "$sm/config/model-catalog.json")" = 1 ] \
    || fail "later convergence removed the first destination after quarantine"
  [ "$(pool_model_count "$sm2/config/model-catalog.json")" = 1 ] \
    || fail "later convergence removed a subsequent destination after quarantine"

  rm -f "$home/config/.model-catalog.invalid-primary"
  find "$home/config" -maxdepth 1 -type f -name 'model-catalog.json.invalid-*' -exec rm -f -- {} +
  run_config_push "$root" "$home" "$fakebin" "$log" >/dev/null
  [ ! -e "$sm/config/model-catalog.json" ] && [ ! -e "$sm2/config/model-catalog.json" ] \
    || fail "explicit invalid-source marker removal did not converge intentional absence"

  pass "invalid catalog is quarantined before publication and leaves the destination unchanged"
}

invalid_destination_and_staged_bytes_converge_safely() {
  local rec root home sm fakebin log fakecp out
  rec=$(new_propagation_world publication-boundary)
  root=${rec%%|*}
  rec=${rec#*|}
  home=${rec%%|*}
  sm=${rec#*|}
  fakebin=$(make_fake_toolchain "$TMP_ROOT/publication-boundary")
  log="$TMP_ROOT/publication-boundary.tmux.log"

  printf '%s' "$(valid_catalog_v1)" > "$home/config/model-catalog.json"
  printf '{"pools":[]}' > "$sm/config/model-catalog.json"
  out=$(run_config_push "$root" "$home" "$fakebin" "$log")
  assert_contains "$out" 'model-catalog.json: pushed' \
    "valid primary did not replace a safely recoverable malformed destination"
  [ "$(pool_model_count "$sm/config/model-catalog.json")" = 1 ] \
    || fail "malformed destination did not converge to the valid primary"
  find "$sm/config" -maxdepth 1 -type f -name 'model-catalog.json.invalid-*' | grep -q . \
    || fail "malformed destination was not preserved in quarantine"

  fakecp="$TMP_ROOT/publication-boundary/fake-cp"
  mkdir -p "$fakecp"
  cat > "$fakecp/cp" <<'SH'
#!/usr/bin/env bash
printf '{"pools":[]}' > "$2"
SH
  chmod +x "$fakecp/cp"
  printf '%s' "$(valid_catalog_v2)" > "$home/config/model-catalog.json"
  if PATH="$fakecp:$BASE_PATH" copy_model_catalog_file \
    "$home/config/model-catalog.json" "$sm/config/model-catalog.json"; then
    fail "publication accepted staged bytes that failed catalog validation"
  fi
  [ "$(pool_model_count "$sm/config/model-catalog.json")" = 1 ] \
    || fail "failed staged-byte validation changed the published destination"

  rm -f "$home/config/model-catalog.json"
  printf '{"pools":[]}' > "$sm/config/model-catalog.json"
  run_config_push "$root" "$home" "$fakebin" "$log" >/dev/null
  [ ! -e "$sm/config/model-catalog.json" ] \
    || fail "primary absence did not remove a safely recoverable malformed destination"
  pass "publication validates staged bytes and recovers malformed destinations"
}

remote_path_converges_before_intake() {
  local rec root home sm fakebin log ssh_bin out reread_line intake_line before_nudges after_nudges push_rc
  rec=$(new_propagation_world remote-catalog)
  root=${rec%%|*}
  rec=${rec#*|}
  home=${rec%%|*}
  sm=${rec#*|}
  fakebin=$(make_fake_toolchain "$TMP_ROOT/remote-catalog")
  log="$TMP_ROOT/remote-catalog.tmux.log"
  ssh_bin="$fakebin/fake-ssh"
  cat > "$home/data/secondmates.md" <<EOF
- sm - remote fixture (host: remote-test; root: $ROOT; home: $sm; scope: test; projects: none; added 2026-08-22)
EOF
  printf 'remote_host=remote-test\n' >> "$home/state/sm.meta"
  cat > "$ssh_bin" <<SH
#!/usr/bin/env bash
while [ "\$#" -gt 0 ]; do
  case "\$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
[ "\$1" = remote-test ] || exit 91
[ "\$2" = fm-remote-entrypoint.sh ] || exit 92
shift 2
shift 3
argv_b64=\$1
args=()
while IFS= read -r -d '' arg; do args+=("\$arg"); done < <(printf '%s' "\$argv_b64" | base64 -d)
command=\${args[0]}
unset 'args[0]'
if [ "\$command" = fm-remote-inherit.sh ] && [ "\${args[1]:-}" = put ] \
  && [ "\${args[2]:-}" = config/backend ] && [ "\${FM_FAKE_REMOTE_FAIL_BACKEND:-0}" = 1 ]; then
  exit 77
fi
if [ "\$command" = fm-remote-secondmate-control.sh ] && [ "\${args[1]:-}" = send ]; then
  printf '%s\n' "\${args[3]}" >> "\$FM_FAKE_TMUX_LOG"
  exit 0
fi
exec env -i PATH="${fakebin}:${BASE_PATH}" FM_HOME="\$FM_FAKE_REMOTE_HOME" \
  "\$FM_FAKE_ROOT/bin/\$command" "\${args[@]}"
SH
  chmod +x "$ssh_bin"

  printf '%s' "$(valid_catalog_v2)" > "$home/config/model-catalog.json"
  touch "$home/state/.last-watcher-beat"
  set +e
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_SEND_SETTLE=0 FM_FAKE_TMUX_LOG="$log" FM_SSH_BIN="$ssh_bin" \
    FM_FAKE_REMOTE_HOME="$sm" FM_FAKE_ROOT="$ROOT" "$CONFIG_PUSH")
  push_rc=$?
  set -e
  [ "$push_rc" -eq 0 ] || fail "remote config push failed: $out"
  assert_contains "$out" 'pushed: config/model-catalog.json' \
    "remote config push did not publish the model catalog"
  assert_contains "$out" 'config-reread: sent' \
    "remote config push did not deliver its durable reread nudge"
  [ "$(pool_model_count "$sm/config/model-catalog.json")" = 3 ] \
    || fail "remote secondmate did not receive the catalog generation"
  printf '%s\n' 'TASK_INTAKE: remote-catalog' >> "$log"
  reread_line=$(grep -nF 'Re-read AGENTS.md and the inherited config files before further work.' "$log" | tail -1 | cut -d: -f1)
  intake_line=$(grep -nF 'TASK_INTAKE: remote-catalog' "$log" | tail -1 | cut -d: -f1)
  [ -n "$reread_line" ] && [ "$reread_line" -lt "$intake_line" ] \
    || fail "remote catalog reread notification did not precede later task intake"
  [ ! -e "$home/state/.secondmate-nudge-pending/sm.pending" ] \
    || fail "remote reread retry marker remained after successful delivery"

  before_nudges=$(grep -cF 'Re-read AGENTS.md and the inherited config files before further work.' "$log" || true)
  printf '{"pools":[]}' > "$home/config/model-catalog.json"
  printf '%s\n' codex > "$home/config/backend"
  set +e
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_SEND_SETTLE=0 FM_FAKE_TMUX_LOG="$log" FM_SSH_BIN="$ssh_bin" \
    FM_FAKE_REMOTE_HOME="$sm" FM_FAKE_ROOT="$ROOT" FM_FAKE_REMOTE_FAIL_BACKEND=1 \
    "$CONFIG_PUSH" 2>&1)
  push_rc=$?
  set -e
  expect_code 1 "$push_rc" "unrelated remote transfer failure must remain a hard failure"
  assert_contains "$out" 'catalog-error: config/model-catalog.json' \
    "remote failure fixture did not first record the catalog-only error"
  assert_present "$home/state/.secondmate-nudge-pending/sm.pending" \
    "unrelated remote failure cleared the durable reread retry marker"
  after_nudges=$(grep -cF 'Re-read AGENTS.md and the inherited config files before further work.' "$log" || true)
  [ "$after_nudges" = "$before_nudges" ] \
    || fail "unrelated remote failure was misclassified and sent a reread nudge"
  pass "remote path publishes and notifies before later task intake"
}

allowlist_declares_model_catalog() {
  local items
  items=$(fm_config_inherit_items)
  assert_contains "$items" 'config/model-catalog.json' \
    "inheritance allowlist must include model-catalog.json"
  pass "inheritance allowlist declares model-catalog.json"
}

local_catalog_send_failure_retries_exact_generation() {
  local rec root home sm fakebin fail_fakebin log retry_log retry_out first_instr
  rec=$(new_propagation_world catalog-retry)
  root=${rec%%|*}
  rec=${rec#*|}
  home=${rec%%|*}
  sm=${rec#*|}
  fakebin=$(make_fake_toolchain "$TMP_ROOT/catalog-retry")
  fail_fakebin=$(make_fake_toolchain "$TMP_ROOT/catalog-retry-fail")
  log="$TMP_ROOT/catalog-retry-fail.tmux.log"
  retry_log="$TMP_ROOT/catalog-retry-success.tmux.log"

  printf '%s' "$(valid_catalog_v1)" > "$home/config/model-catalog.json"
  : > "$home/state/sm.inbox"
  run_config_push "$root" "$home" "$fail_fakebin" "$log" >/dev/null 2>&1 || true
  first_instr=$(latest_reread_instruction "$sm") || fail "send failure should still retain a generation"
  assert_present "$sm/state/${first_instr##*/}.pending" \
    "send failure must record a retry marker"

  printf '%s' "$(valid_catalog_v2)" > "$home/config/model-catalog.json"
  rm -f "$home/state/sm.inbox"
  run_config_push "$root" "$home" "$fakebin" "$retry_log" >/dev/null
  retry_out=$(inbox_stream "$home/state" sm)
  assert_contains "$retry_out" "CONFIG_REREAD: $first_instr" \
    "retry must deliver the earlier pending generation before later intake"
  [ "$(pool_model_count "$sm/config/model-catalog.json")" = 3 ] \
    || fail "retry path did not converge the newer catalog generation"
  pass "catalog reread send failures retain and later retry the exact generation"
}

catalog_converges_with_reread_before_intake
invalid_catalog_is_quarantined_at_publication
invalid_destination_and_staged_bytes_converge_safely
remote_path_converges_before_intake
allowlist_declares_model_catalog
local_catalog_send_failure_retries_exact_generation

echo '# all fm-model-catalog-inheritance tests passed'
