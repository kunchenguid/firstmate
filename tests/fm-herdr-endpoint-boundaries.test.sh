#!/usr/bin/env bash
# Fixture overrides are invoked by the dynamically loaded production modules.
# shellcheck disable=SC2329
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-test-safety.sh"
command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found'; exit 0; }
herdr_forget_inherited_pane
TMP_ROOT=$(fm_test_tmproot fm-herdr-boundaries)

write_proc() {
  mkdir -p "$1/$2" "$1/sys/kernel/random"
  printf '%s (sh) S 1 %s %s 0 -1 4194304 100 0 0 0 0 0 0 0 20 0 1 0 %s 1000 100 18446744073709551615\n' \
    "$2" "$2" "$2" "$3" > "$1/$2/stat"
  printf '3f2a9c1e-0000-4000-8000-0123456789ab\n' > "$1/sys/kernel/random/boot_id"
}

write_pane() {
  local pane=$1 pid=$2 cwd=$3 agent=${4:-pi} key=${1//:/_} ws=${1%%:*}
  jq -n --arg pane "$pane" --arg tab "$ws:t${pane##*:p}" --arg ws "$ws" --arg cwd "$cwd" \
    '{result:{pane:{pane_id:$pane,tab_id:$tab,workspace_id:$ws,cwd:$cwd,foreground_cwd:$cwd}}}' > "$FM_FAKE_WORLD/pane-$key.json"
  jq -n --arg pane "$pane" --argjson pid "$pid" \
    '{result:{type:"pane_process_info",process_info:{pane_id:$pane,shell_pid:$pid}}}' > "$FM_FAKE_WORLD/process-$key.json"
  jq -n --arg agent "$agent" '{result:{agent:{agent:$agent,agent_status:"idle"}}}' > "$FM_FAKE_WORLD/agent-$key.json"
  printf '' > "$FM_FAKE_WORLD/composer-$key"
}

setup_world() {
  local dir=$1
  export FM_FAKE_WORLD="$dir/world" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" FM_PROC_ROOT_OVERRIDE="$dir/proc"
  mkdir -p "$FM_FAKE_WORLD" "$FM_STATE_OVERRIDE" "$dir/fakebin"
  write_proc "$FM_PROC_ROOT_OVERRIDE" 42 7000
  write_proc "$FM_PROC_ROOT_OVERRIDE" 43 7100
  cat > "$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
w=$FM_FAKE_WORLD
pane=${3:-}; key=${pane//:/_}
case "${1:-} ${2:-}" in
  'status --json') printf '{"client":{"version":"0.9.3","protocol":22},"server":{"running":true}}\n' ;;
  'server '*) ;;
  'session list') printf '{"sessions":[{"name":"fmtest","running":true,"socket_path":"%s/fmtest.sock"}]}\n' "$w" ;;
  'workspace list') cat "$w/workspaces.json" ;;
  'workspace get') printf '{"result":{"workspace":{"workspace_id":"w1","label":"firstmate"}}}\n' ;;
  'pane get')
    if [ "${FM_RESET_STAGE:-}" = cwd ]; then
      n=0; [ ! -f "$w/pane-reads" ] || read -r n < "$w/pane-reads"
      n=$((n + 1)); printf '%s\n' "$n" > "$w/pane-reads"
      [ "$n" -ne 2 ] || "$w/reset"
    fi
    cat "$w/pane-$key.json" 2>/dev/null || { printf '{"error":{"code":"pane_not_found"}}\n'; exit 1; }
    ;;
  'pane process-info') key=${4//:/_}; cat "$w/process-$key.json" ;;
  'agent get') printf '%s\n' "$pane" >> "$w/agent-reads"; cat "$w/agent-$key.json" ;;
  'pane list') cat "$w/panes.json" ;;
  'tab list')
    if [ "${FM_HUSK_DUP:-0}" = 1 ] && [ ! -f "$w/closed-tab" ]; then
      printf '{"result":{"tabs":[{"tab_id":"w1:t1","label":"fm-mine"}]}}\n'
    else
      printf '{"result":{"tabs":[]}}\n'
    fi
    ;;
  'tab get') printf '{"result":{"tab":{"tab_id":"%s","workspace_id":"%s","label":"fm-mine"}}}\n' "$pane" "${pane%%:*}" ;;
  'tab create')
    [ "${FM_RESET_STAGE:-}" != husk ] || "$w/reset"
    printf '{"result":{"tab":{"tab_id":"w1:t3","workspace_id":"w1"},"root_pane":{"pane_id":"w1:p3"}}}\n'
    ;;
  'pane read')
    printf '%s\n' "$pane" >> "$w/reads"
    printf '❯ %s\n' "$(cat "$w/composer-$key")"
    ;;
  'pane send-text')
    printf '%s %s\n' "$pane" "$2" >> "$w/inputs"
    printf '%s' "$4" > "$w/composer-$key"
    : > "$w/typed"
    ;;
  'pane send-keys'|'pane run'|'pane close'|'tab close')
    printf '%s %s %s\n' "$pane" "$2" "${4:-}" >> "$w/inputs"
    [ "$1 $2" != 'tab close' ] || : > "$w/closed-tab"
    if [ "$2" = close ] && [ "${FM_CLOSE_REMOVES:-0}" = 1 ]; then
      rm -f "$w/pane-$key.json" "$w/process-$key.json" "$w/agent-$key.json"
    fi
    if [ "$2" = send-keys ] && [ "${4:-}" = enter ]; then
      : > "$w/entered"
      [ "${FM_KEEP_COMPOSER:-0}" = 1 ] || : > "$w/composer-$key"
    fi
    ;;
esac
SH
  chmod +x "$dir/fakebin/herdr"
  export PATH="$dir/fakebin:$PATH"
  printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate","active_tab_id":"w1:t1","focused":true}]}}\n' > "$FM_FAKE_WORLD/workspaces.json"
  printf '{"result":{"panes":[]}}\n' > "$FM_FAKE_WORLD/panes.json"
  : > "$FM_FAKE_WORLD/inputs"; : > "$FM_FAKE_WORLD/reads"
  . "$ROOT/bin/fm-backend.sh"
  fm_backend_source herdr
  export FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0 FM_BACKEND_HERDR_SUBMIT_POLLS=1
}

bind_mine() {
  printf 'backend=herdr\nwindow=fmtest:w1:p1\nherdr_process_identity=proc:42:3f2a9c1e-0000-4000-8000-0123456789ab:7000\n' > "$FM_STATE_OVERRIDE/mine.meta"
  printf 'backend=herdr\nwindow=fmtest:w1:p1\nherdr_process_identity=proc:43:3f2a9c1e-0000-4000-8000-0123456789ab:7100\n' > "$FM_STATE_OVERRIDE/other.meta"
}

reset_pane() {
  cp "$FM_FAKE_WORLD/reads" "$FM_FAKE_WORLD/reads-at-reset"
  write_pane w1:p1 43 "$FM_HOME" claude
  printf 'foreign draft' > "$FM_FAKE_WORLD/composer-w1_p1"
}

test_dispatch_boundaries() {
  local op out
  for op in capture visible key busy composer; do
    (
      setup_world "$TMP_ROOT/dispatch-$op"
      write_pane w1:p1 42 "$FM_HOME" claude
      bind_mine
      fm_backend_herdr_server_ensure() {
        local n=0
        [ ! -f "$FM_FAKE_WORLD/ready-count" ] || read -r n < "$FM_FAKE_WORLD/ready-count"
        n=$((n + 1)); printf '%s\n' "$n" > "$FM_FAKE_WORLD/ready-count"
        [ "$n" -ne 2 ] || reset_pane
        return 0
      }
      case "$op" in
        capture) ! fm_backend_capture herdr fmtest:w1:p1 5 fm-mine || fail 'capture crossed a reset' ;;
        visible) ! fm_backend_visible_capture herdr fmtest:w1:p1 fm-mine || fail 'viewport crossed a reset' ;;
        key) ! fm_backend_send_key herdr fmtest:w1:p1 C-u fm-mine || fail 'key crossed a reset' ;;
        busy) out=$(fm_backend_busy_state herdr fmtest:w1:p1 fm-mine); [ "$out" = unknown ] || fail "busy borrowed foreign state: $out" ;;
        composer) out=$(fm_backend_composer_state herdr fmtest:w1:p1 fm-mine); [ "$out" = unknown ] || fail "composer borrowed foreign state: $out" ;;
      esac
      [ ! -s "$FM_FAKE_WORLD/inputs" ] && [ ! -s "$FM_FAKE_WORLD/reads" ] || fail "$op reached the replacement pane"
    ) || fail "$op boundary regression"
  done
  pass 'dispatchers revalidate the selected binding at their internal boundary'
}

test_submit_boundaries() {
  local agent phase out keys
  for agent in claude pi; do
    for phase in ordinary settle confirm; do
      (
        setup_world "$TMP_ROOT/submit-$agent-$phase"
        write_pane w1:p1 42 "$FM_HOME" "$agent"
        bind_mine
        export FM_KEEP_COMPOSER=0
        [ "$phase" != confirm ] || export FM_KEEP_COMPOSER=1
        sleep() {
          case "$phase" in
            settle) [ ! -f "$FM_FAKE_WORLD/typed" ] || reset_pane ;;
            confirm) [ ! -f "$FM_FAKE_WORLD/entered" ] || reset_pane ;;
          esac
        }
        out=$(fm_backend_send_text_submit herdr fmtest:w1:p1 payload 2 0 0 fm-mine) || fail 'submit call failed'
        keys=$(grep -c 'send-keys' "$FM_FAKE_WORLD/inputs" || true)
        case "$phase" in
          ordinary) [ "$out" = empty ] && [ "$keys" = 1 ] || fail "ordinary $agent submit regressed: $out / $keys" ;;
          settle) [ "$out" != empty ] && [ "$keys" = 0 ] || fail "settle reset submitted or erased a foreign draft: $out / $keys" ;;
          confirm) [ "$out" = unknown ] && [ "$keys" = 1 ] || fail "confirmation reset borrowed foreign delivery or retried Enter: $out / $keys" ;;
        esac
        if [ "$phase" != ordinary ]; then
          [ "$(cat "$FM_FAKE_WORLD/composer-w1_p1")" = 'foreign draft' ] || fail 'foreign draft was modified'
          cmp -s "$FM_FAKE_WORLD/reads" "$FM_FAKE_WORLD/reads-at-reset" || fail 'submit read the replacement pane'
        fi
      ) || fail "$agent/$phase submit regression"
    done
  done
  pass 'submit settlement and confirmation resets neither read nor modify foreign drafts'
}

test_identity_requires_boot_and_ticks() {
  (
    setup_world "$TMP_ROOT/identity"
    write_pane w1:p1 42 "$FM_HOME"
    cat > "$TMP_ROOT/identity/fakebin/ps" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_LSTART:-Wed Oct  7 02:03:32 2026}"
SH
    chmod +x "$TMP_ROOT/identity/fakebin/ps"
    local boot identity
    for boot in missing empty malformed; do
      case "$boot" in
        missing) rm -f "$FM_PROC_ROOT_OVERRIDE/sys/kernel/random/boot_id" ;;
        empty) : > "$FM_PROC_ROOT_OVERRIDE/sys/kernel/random/boot_id" ;;
        malformed) printf '%s\n' '-' > "$FM_PROC_ROOT_OVERRIDE/sys/kernel/random/boot_id" ;;
      esac
      identity=$(fm_backend_herdr_pane_process_identity fmtest w1:p1) || fail 'fallback identity unreadable'
      [ "$identity" = 'ps:42:Wed Oct  7 02:03:32 2026' ] || fail "$boot boot id produced a partial proc identity"
      FM_LSTART='Wed Oct  7 02:03:31 2026' fm_backend_herdr_identity_matches fmtest w1:p1 "$identity" || fail 'fallback rejected negative drift'
      FM_LSTART='Wed Oct  7 02:03:33 2026' fm_backend_herdr_identity_matches fmtest w1:p1 "$identity" || fail 'fallback rejected positive drift'
      ! fm_backend_herdr_identity_matches fmtest w1:p1 'proc:42:-:7000' || fail 'partial proc binding was accepted'
    done
    write_proc "$FM_PROC_ROOT_OVERRIDE" 42 7000
    identity=$(fm_backend_herdr_pane_process_identity fmtest w1:p1)
    [ "$identity" = 'proc:42:3f2a9c1e-0000-4000-8000-0123456789ab:7000' ] || fail 'complete proc identity regressed'
  ) || fail 'two-format identity regression'
  pass 'missing boot identity uses drift-tolerant ps, never partial proc'
}

test_teardown_preserves_foreign_processes() {
  local scenario
  for scenario in flat projected descendants descendant-process; do
    (
      local dir="$TMP_ROOT/teardown-$scenario" wt proj mate out pid state target
      setup_world "$dir"
      wt="$dir/wt"; proj="$dir/project"; state="$FM_STATE_OVERRIDE"; target=w1:p1
      fm_git_worktree "$proj" "$wt" foreign-worker
      mkdir -p "$FM_HOME/data" "$FM_HOME/config" "$dir/user-home"
      (cd "$wt" && exec sleep 300) & pid=$!
      trap 'kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true' EXIT
      write_proc "$FM_PROC_ROOT_OVERRIDE" "$pid" 7200
      write_pane "$target" "$pid" "$wt"
      if [ "$scenario" = descendants ]; then
        mate="$dir/mate"; mkdir -p "$mate/state" "$mate/data" "$mate/config"
        printf 'mine\n' > "$mate/.fm-secondmate-home"
        fm_write_meta "$state/mine.meta" backend=herdr window=fmtest:w1:p2 endpoint_task_id=mine \
          "worktree=$mate" "project=$mate" "home=$mate" kind=secondmate harness=pi mode=secondmate yolo=off \
          herdr_session=fmtest herdr_workspace_id=w1 herdr_tab_id=w1:t2 herdr_pane_id=w1:p2 \
          'herdr_process_identity=proc:42:3f2a9c1e-0000-4000-8000-0123456789ab:7000'
        write_pane w1:p2 43 "$dir/unrelated"
        state="$mate/state"
      fi
      fm_write_meta "$state/mine.meta" backend=herdr window=fmtest:w1:p1 endpoint_task_id=mine \
        "worktree=$wt" "project=$proj" kind=scout harness=pi \
        herdr_session=fmtest herdr_workspace_id=w1 herdr_tab_id=w1:t1 herdr_pane_id=w1:p1 \
        'herdr_process_identity=proc:42:3f2a9c1e-0000-4000-8000-0123456789ab:7000'
      if [ "$scenario" = descendant-process ]; then
        write_pane w1:p1 "$BASHPID" "$dir/unrelated"
        write_proc "$FM_PROC_ROOT_OVERRIDE" "$BASHPID" 7300
      fi
      if [ "$scenario" = projected ]; then
        local token
        token=$(fm_backend_herdr_projection_journal_create "$state" mine) || fail 'journal creation failed'
        fm_backend_herdr_projection_journal_bind "$state/mine.herdr-presentation" mine "$FM_HOME" fmtest \
          w1 w1:t1 w1:p1 w2 firstmate "└ mine · p:$token" fm-mine || fail 'journal binding failed'
      fi
      cat > "$dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
printf 'p%s\nfcwd\nn%s\n' "$FM_FOREIGN_PID" "$FM_FOREIGN_WT"
SH
      cat > "$dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_WORLD/returns"
SH
      chmod +x "$dir/fakebin/lsof" "$dir/fakebin/treehouse"
      out=$(FM_FOREIGN_PID="$pid" FM_FOREIGN_WT="$wt" HOME="$dir/user-home" FM_ROOT_OVERRIDE="$FM_HOME" \
        "$ROOT/bin/fm-teardown.sh" mine --force 2>&1) && fail "$scenario teardown accepted a destructive cleanup"
      assert_contains "$out" 'foreign herdr' "$scenario refusal did not explain foreign ownership"
      kill -0 "$pid" 2>/dev/null || fail "$scenario teardown signalled the foreign process"
      [ -f "$state/mine.meta" ] && [ -d "$wt" ] || fail "$scenario teardown removed durable state or worktree"
      [ ! -s "$FM_FAKE_WORLD/returns" ] && [ ! -s "$FM_FAKE_WORLD/inputs" ] || fail "$scenario teardown returned a worktree or closed the foreign pane"
    ) || fail "$scenario cleanup regression"
  done
  pass 'flat, projected, and recursive cleanup preserve foreign pane processes'
}

test_projection_recovery_ignores_only_bound_foreign_panes() {
  (
    local dir="$TMP_ROOT/projection" journal token label rc
    setup_world "$dir"
    write_pane w1:p1 43 "$FM_HOME"
    bind_mine
    journal="$FM_STATE_OVERRIDE/mine.herdr-presentation"
    token=$(fm_backend_herdr_projection_journal_create "$FM_STATE_OVERRIDE" mine) || fail 'journal creation failed'
    label="└ mine · p:$token"
    fm_backend_herdr_projection_journal_bind "$journal" mine "$FM_HOME" fmtest \
      w1 w1:t1 w1:p1 w2 firstmate "$label" fm-mine || fail 'journal binding failed'
    jq -n --arg label "$label" '{result:{workspaces:[{workspace_id:"w1",label:$label}]}}' > "$FM_FAKE_WORLD/workspaces.json"
    printf '{"result":{"panes":[{"pane_id":"w1:p1"}]}}\n' > "$FM_FAKE_WORLD/panes.json"
    fm_backend_herdr_pane_agent_state() { printf live; }
    fm_backend_herdr_projection_live_binding_matches() { return 0; }
    fm_backend_herdr_projection_recovery_allows_flat fmtest "$journal" mine || fail 'foreign recorded pane blocked flat recovery'
    rc=0
    fm_backend_herdr_projection_reclaim_task fmtest "$journal" mine "$FM_HOME" \
      w1 w1:t1 w1:p1 firstmate fm-mine "$FM_HOME" || rc=$?
    [ "$rc" = 2 ] || fail "foreign recorded pane was reclaimed or blocked fallback: $rc"
    printf '{"result":{"panes":[{"pane_id":"w1:p1"},{"pane_id":"w1:p2"}]}}\n' > "$FM_FAKE_WORLD/panes.json"
    ! fm_backend_herdr_projection_recovery_allows_flat fmtest "$journal" mine || fail 'unbound live presentation candidate was ignored'
    [ ! -s "$FM_FAKE_WORLD/inputs" ] || fail 'recovery modified the foreign pane'
  ) || fail 'presentation recovery regression'
  pass 'presentation recovery distinguishes foreign recorded panes from unbound live candidates'
}

test_ordinary_teardown_and_projected_restart() {
  (
    local dir="$TMP_ROOT/ordinary-teardown" out
    setup_world "$dir"
    mkdir -p "$FM_HOME/data" "$FM_HOME/config" "$dir/user-home"
    write_pane w1:p1 42 "$dir/unrelated"
    fm_write_meta "$FM_STATE_OVERRIDE/mine.meta" backend=herdr window=fmtest:w1:p1 endpoint_task_id=mine \
      "worktree=$dir/missing-worktree" "project=$dir/missing-project" kind=scout harness=pi \
      herdr_session=fmtest herdr_workspace_id=w1 herdr_tab_id=w1:t1 herdr_pane_id=w1:p1 \
      'herdr_process_identity=proc:42:3f2a9c1e-0000-4000-8000-0123456789ab:7000'
    fm_fake_exit0 "$dir/fakebin" lsof treehouse
    out=$(FM_CLOSE_REMOVES=1 HOME="$dir/user-home" FM_ROOT_OVERRIDE="$FM_HOME" \
      "$ROOT/bin/fm-teardown.sh" mine --force 2>&1) || fail "owned cleanup regressed: $out"
    [ ! -f "$FM_STATE_OVERRIDE/mine.meta" ] && [ ! -f "$FM_FAKE_WORLD/pane-w1_p1.json" ] || fail 'ordinary cleanup did not close and retire the owned endpoint'
  ) || fail 'owned cleanup regression'
  (
    local dir="$TMP_ROOT/projected-restart" wt proj token label out
    setup_world "$dir"
    wt="$dir/wt"; proj="$dir/project"
    fm_test_spawn_home "$FM_HOME" codex
    fm_test_spawn_brief "$FM_HOME" mine
    fm_git_worktree "$proj" "$wt" restart-mine
    fm_fake_exit0 "$dir/fakebin" codex treehouse gh-axi
    fm_test_fake_tmux_spawn "$dir/fakebin"
    fm_test_fake_sleep_noop "$dir/fakebin"
    printf 'on\n' > "$FM_HOME/config/herdr-presentation-spaces"
    write_pane w2:p2 43 "$dir/unrelated" codex
    write_pane w1:p3 43 "$wt" codex
    fm_write_meta "$FM_STATE_OVERRIDE/mine.meta" backend=herdr window=fmtest:w2:p2 endpoint_task_id=mine \
      "worktree=$wt" "project=$proj" kind=ship harness=codex mode=no-mistakes yolo=off \
      herdr_session=fmtest herdr_workspace_id=w2 herdr_tab_id=w2:t2 herdr_pane_id=w2:p2 \
      'herdr_process_identity=proc:42:3f2a9c1e-0000-4000-8000-0123456789ab:7000'
    token=$(fm_backend_herdr_projection_journal_create "$FM_STATE_OVERRIDE" mine) || fail 'restart journal creation failed'
    label="└ mine · p:$token"
    fm_backend_herdr_projection_journal_bind "$FM_STATE_OVERRIDE/mine.herdr-presentation" mine "$FM_HOME" fmtest \
      w2 w2:t2 w2:p2 w1 firstmate "$label" fm-mine || fail 'restart journal binding failed'
    jq -n --arg label "$label" '{result:{workspaces:[{workspace_id:"w1",label:"firstmate"},{workspace_id:"w2",label:$label}]}}' > "$FM_FAKE_WORLD/workspaces.json"
    printf '{"result":{"panes":[{"pane_id":"w2:p2"}]}}\n' > "$FM_FAKE_WORLD/panes.json"
    out=$(HERDR_SESSION=fmtest fm_test_run_spawn "$FM_HOME" "$wt" "$dir/fakebin" mine "$proj" \
      --backend herdr --mode no-mistakes --yolo off) || fail "projected restart refused a recycled endpoint: $out"
    [ "$(fm_backend_target_of_meta "$FM_STATE_OVERRIDE/mine.meta")" = fmtest:w1:p3 ] || fail 'projected restart did not recover flat'
    [ -f "$FM_FAKE_WORLD/pane-w2_p2.json" ] || fail 'projected restart removed the foreign endpoint'
    ! grep -q '^w2:p2 ' "$FM_FAKE_WORLD/inputs" || fail 'projected restart steered or closed the foreign endpoint'
  ) || fail 'projected restart regression'
  pass 'ordinary cleanup still completes and projected restart recovers flat after a reset'
}

prepare_reset() {
  local pane=${1:-w1:p1} key=${1//:/_}
  export FM_RESET_PANE=$pane
  cp "$FM_FAKE_WORLD/pane-$key.json" "$FM_FAKE_WORLD/reset-pane.json"
  cp "$FM_FAKE_WORLD/process-$key.json" "$FM_FAKE_WORLD/reset-process.json"
  cat > "$FM_FAKE_WORLD/reset" <<'SH'
#!/usr/bin/env bash
w=$FM_FAKE_WORLD
[ ! -f "$w/reset-done" ] || exit 0
key=${FM_RESET_PANE//:/_}
if [ -f "$FM_STATE_OVERRIDE/mine.meta" ]; then cp "$FM_STATE_OVERRIDE/mine.meta" "$w/meta-at-reset"; fi
cp "$w/inputs" "$w/inputs-at-reset"
jq '.result.process_info.shell_pid = 43' "$w/reset-process.json" > "$w/process-$key.json"
jq --arg cwd "${FM_RESET_CWD:-$FM_HOME}" '.result.pane.foreground_cwd = $cwd | .result.pane.cwd = $cwd' "$w/reset-pane.json" > "$w/pane-$key.json"
printf 'foreign draft' > "$w/composer-$key"
: > "$w/reset-done"
SH
  chmod +x "$FM_FAKE_WORLD/reset"
}

test_adopted_relaunch_keeps_its_previous_binding() {
  local stage
  for stage in ordinary cwd literal key; do
    (
      local dir="$TMP_ROOT/adopted-$stage" wt proj out
      setup_world "$dir"
      wt="$dir/wt"; proj="$dir/project"
      fm_test_spawn_home "$FM_HOME" codex
      fm_test_spawn_brief "$FM_HOME" mine
      fm_git_worktree "$proj" "$wt" adopted-mine
      fm_fake_exit0 "$dir/fakebin" codex treehouse gh-axi
      fm_test_fake_tmux_spawn "$dir/fakebin"
      printf 'off\n' > "$FM_HOME/config/herdr-presentation-spaces"
      write_pane w1:p1 42 "$wt" codex
      printf '{"error":{"code":"agent_not_found"}}\n' > "$FM_FAKE_WORLD/agent-w1_p1.json"
      fm_write_meta "$FM_STATE_OVERRIDE/mine.meta" backend=herdr window=fmtest:w1:p1 endpoint_task_id=mine \
        "worktree=$wt" "project=$proj" kind=ship harness=codex mode=no-mistakes yolo=off \
        herdr_session=fmtest herdr_workspace_id=w1 herdr_tab_id=w1:t1 herdr_pane_id=w1:p1 \
        'herdr_process_identity=proc:42:3f2a9c1e-0000-4000-8000-0123456789ab:7000'
      cp "$FM_STATE_OVERRIDE/mine.meta" "$dir/prior.meta"
      prepare_reset w1:p1
      cat > "$dir/fakebin/sleep" <<'SH'
#!/usr/bin/env bash
case "${FM_RESET_STAGE:-}" in
  literal)
    if grep -q '^spawn_gen=' "$FM_STATE_OVERRIDE/mine.meta"; then "$FM_FAKE_WORLD/reset"; fi
    ;;
  key) [ ! -f "$FM_FAKE_WORLD/typed" ] || "$FM_FAKE_WORLD/reset" ;;
esac
exit 0
SH
      chmod +x "$dir/fakebin/sleep"
      # shellcheck disable=SC2030 # Reset stage is intentionally confined to this fixture's subshell.
      export FM_RESET_STAGE=$stage
      if out=$(HERDR_SESSION=fmtest fm_test_run_spawn "$FM_HOME" "$wt" "$dir/fakebin" mine --relaunch 2>&1); then
        [ "$stage" = ordinary ] || fail "$stage relaunch adopted a recycled pane: $out"
      else
        [ "$stage" != ordinary ] || fail "ordinary adopted relaunch regressed: $out"
      fi
      if [ "$stage" = ordinary ]; then
        [ "$(fm_backend_target_of_meta "$FM_STATE_OVERRIDE/mine.meta")" = fmtest:w1:p1 ] || fail 'ordinary adoption changed the endpoint'
        grep -q 'w1:p1 send-keys enter' "$FM_FAKE_WORLD/inputs" || fail 'ordinary adopted relaunch did not deliver Enter'
      else
        [ -f "$FM_FAKE_WORLD/reset-done" ] || fail "$stage relaunch did not exercise a reset"
        cmp -s "$FM_FAKE_WORLD/inputs" "$FM_FAKE_WORLD/inputs-at-reset" || fail "$stage relaunch sent input to the recycled pane"
        [ "$(cat "$FM_FAKE_WORLD/composer-w1_p1")" = 'foreign draft' ] || fail "$stage relaunch changed a foreign draft"
        [ "$(fm_backend_herdr_meta_value "$FM_STATE_OVERRIDE/mine.meta" herdr_process_identity)" = 'proc:42:3f2a9c1e-0000-4000-8000-0123456789ab:7000' ] || fail "$stage relaunch published foreign ownership"
        [ "$stage" != cwd ] || cmp -s "$dir/prior.meta" "$FM_STATE_OVERRIDE/mine.meta" || fail 'cwd refusal replaced the previous record'
      fi
    ) || fail "$stage adopted relaunch regression"
  done
  pass 'adopted relaunch refuses recycled panes at cwd, launch text, and Enter boundaries'
}

test_close_fallback_rechecks_the_selected_binding() {
  local path scope
  for path in ordinary projected; do
    for scope in parent child; do
      (
        local dir="$TMP_ROOT/close-$path-$scope" rc=0
        setup_world "$dir"
        write_pane w1:p1 42 "$FM_HOME"
        bind_mine
        if [ "$scope" = child ]; then
          mkdir -p "$dir/child/state"
          cp "$FM_STATE_OVERRIDE/mine.meta" "$dir/child/state/mine.meta"
          cp "$FM_STATE_OVERRIDE/other.meta" "$FM_STATE_OVERRIDE/mine.meta"
          # shellcheck disable=SC2030 # Child state is intentionally confined to this fixture's subshell.
          export FM_STATE_OVERRIDE="$dir/child/state"
        fi
        prepare_reset w1:p1
        # shellcheck disable=SC2030 # Close settings are intentionally confined to this fixture's subshell.
        export FM_CLOSE_REMOVES=1 FM_BACKEND_HERDR_DEATH_CLOSE_POLLS=1
        fm_backend_herdr_projection_focus_snapshot() { printf 'w2\tw2:t2'; }
        fm_backend_herdr_projection_focus_restore() { return 0; }
        fm_backend_herdr_projection_target_tab_mutation_allowed() { return 0; }
        fm_backend_herdr_emptying_close_plan() { printf 'death 42'; }
        fm_backend_herdr_pid_is_bare_shell() { return 0; }
        fm_backend_herdr_pane_idle_shell_sample() { fm_backend_herdr_pane_shell_pid "$@"; }
        kill() { printf '%s\n' "$*" >> "$FM_FAKE_WORLD/signals"; }
        sleep() { "$FM_FAKE_WORLD/reset"; }
        if [ "$path" = ordinary ]; then
          fm_backend_herdr_kill_serialized fmtest w1:p1 fm-mine || rc=$?
        else
          fm_backend_herdr_projection_close_pane_focus_preserving fmtest w1:p1 '' fm-mine || rc=$?
          [ "$rc" != 0 ] || fail 'projected close claimed removal of a foreign endpoint'
        fi
        [ -f "$FM_FAKE_WORLD/reset-done" ] || fail 'close did not cross the death-poll reset'
        [ "$(cat "$FM_FAKE_WORLD/signals")" = '-HUP 42' ] || fail 'close escalated against a replacement process'
        [ -f "$FM_FAKE_WORLD/pane-w1_p1.json" ] && [ ! -s "$FM_FAKE_WORLD/inputs" ] || fail "$path fallback explicitly closed a foreign pane"
      ) || fail "$path/$scope close fallback regression"
    done
  done
  (
    setup_world "$TMP_ROOT/creation-close"
    write_pane w1:p1 43 "$FM_HOME"
    bind_mine
    # shellcheck disable=SC2030,SC2031 # This fixture sets its own close behavior, independent of earlier subshells.
    export FM_CLOSE_REMOVES=1
    fm_backend_herdr_projection_focus_snapshot() { printf 'w2\tw2:t2'; }
    fm_backend_herdr_projection_focus_restore() { return 0; }
    fm_backend_herdr_projection_target_tab_mutation_allowed() { return 0; }
    fm_backend_herdr_emptying_close_plan() { printf plain; }
    fm_backend_herdr_projection_close_pane_focus_preserving fmtest w1:p1 || fail 'creation-response cleanup was blocked by a stale record'
    [ ! -f "$FM_FAKE_WORLD/pane-w1_p1.json" ] || fail 'creation-response cleanup did not remove its pane'
  ) || fail 'creation-response close regression'
  pass 'ordinary and projected death-close fallbacks preserve recycled panes in the selected home'
}

test_treehouse_return_retry_rechecks_ownership() {
  local path
  for path in main descendant; do
    (
      local dir="$TMP_ROOT/return-$path" wt proj state mate out task=mine
      setup_world "$dir"
      wt="$dir/wt"; proj="$dir/project"
      # shellcheck disable=SC2031 # setup_world initializes state in this fixture's subshell.
      state="$FM_STATE_OVERRIDE"
      fm_git_worktree "$proj" "$wt" return-mine
      mkdir -p "$FM_HOME/data" "$FM_HOME/config" "$dir/user-home"
      write_pane w1:p1 42 "$wt"
      if [ "$path" = descendant ]; then
        mate="$dir/mate"; mkdir -p "$mate/state" "$mate/data" "$mate/config"
        printf 'mine\n' > "$mate/.fm-secondmate-home"
        write_pane w1:p2 43 "$mate"
        fm_write_meta "$state/mine.meta" backend=herdr window=fmtest:w1:p2 endpoint_task_id=mine \
          "worktree=$mate" "project=$mate" "home=$mate" kind=secondmate harness=pi mode=secondmate yolo=off \
          herdr_session=fmtest herdr_workspace_id=w1 herdr_tab_id=w1:t2 herdr_pane_id=w1:p2 \
          'herdr_process_identity=proc:43:3f2a9c1e-0000-4000-8000-0123456789ab:7100'
        state="$mate/state"; task=leaf
      fi
      fm_write_meta "$state/$task.meta" backend=herdr window=fmtest:w1:p1 "endpoint_task_id=$task" \
        "worktree=$wt" "project=$proj" kind=scout harness=pi \
        herdr_session=fmtest herdr_workspace_id=w1 herdr_tab_id=w1:t1 herdr_pane_id=w1:p1 \
        'herdr_process_identity=proc:42:3f2a9c1e-0000-4000-8000-0123456789ab:7000'
      prepare_reset w1:p1
      fm_fake_exit0 "$dir/fakebin" lsof
      cat > "$dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_WORLD/returns"
if [ "$(wc -l < "$FM_FAKE_WORLD/returns")" -eq 1 ]; then
  printf "fatal: Unable to create '%s/.git/index.lock': File exists.\n" "$FM_RESET_CWD" >&2
  exit 1
fi
printf '%s\n' destructive-retry > "$FM_FAKE_WORLD/destructive-retry"
SH
      cat > "$dir/fakebin/sleep" <<'SH'
#!/usr/bin/env bash
[ ! -f "$FM_FAKE_WORLD/returns" ] || "$FM_FAKE_WORLD/reset"
exit 0
SH
      chmod +x "$dir/fakebin/treehouse" "$dir/fakebin/sleep"
      out=$(FM_RESET_CWD="$wt" FM_CLOSE_REMOVES=1 FM_TREEHOUSE_RETURN_LOCK_RETRIES=1 FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=0 \
        HOME="$dir/user-home" FM_ROOT_OVERRIDE="$FM_HOME" "$ROOT/bin/fm-teardown.sh" mine --force 2>&1) && fail "$path cleanup accepted a foreign retry"
      assert_contains "$out" 'foreign herdr' "$path retry did not identify foreign ownership"
      [ -f "$FM_FAKE_WORLD/reset-done" ] || fail "$path return never reached its retry wait"
      [ ! -f "$FM_FAKE_WORLD/destructive-retry" ] && [ "$(wc -l < "$FM_FAKE_WORLD/returns")" -eq 1 ] || fail "$path return retried against foreign ownership"
      [ -f "$state/$task.meta" ] && [ -d "$wt" ] && [ -f "$FM_FAKE_WORLD/pane-w1_p1.json" ] || fail "$path retry removed durable state, worktree, or foreign pane"
      cmp -s "$FM_FAKE_WORLD/inputs" "$FM_FAKE_WORLD/inputs-at-reset" || fail "$path retry closed the foreign pane"
    ) || fail "$path Treehouse retry regression"
  done
  pass 'main and descendant Treehouse retries retain the selected ownership context'
}

test_deferred_husk_close_rechecks_ownership() {
  local stage
  for stage in ordinary husk; do
    (
      local dir="$TMP_ROOT/husk-$stage" out
      setup_world "$dir"
      write_pane w1:p1 42 "$FM_HOME"
      printf '{"error":{"code":"agent_not_found"}}\n' > "$FM_FAKE_WORLD/agent-w1_p1.json"
      bind_mine
      prepare_reset w1:p1
      printf '{"result":{"panes":[{"pane_id":"w1:p1","tab_id":"w1:t1"}]}}\n' > "$FM_FAKE_WORLD/panes.json"
      # shellcheck disable=SC2030,SC2031 # This fixture sets its own reset stage, independent of earlier subshells.
      export FM_RESET_STAGE=$stage FM_HUSK_DUP=1
      out=$(fm_backend_herdr_create_task fmtest:w1 fm-mine "$FM_HOME" '') || fail "$stage husk replacement failed"
      [ "$out" = 'w1:t3 w1:p3' ] || fail "$stage replacement returned an unexpected endpoint: $out"
      if [ "$stage" = husk ]; then
        [ -f "$FM_FAKE_WORLD/reset-done" ] && [ ! -s "$FM_FAKE_WORLD/inputs" ] && [ ! -f "$FM_FAKE_WORLD/closed-tab" ] || fail 'deferred tab close reached a recycled pane'
      else
        [ -f "$FM_FAKE_WORLD/closed-tab" ] || fail 'ordinary replacement did not close its owned husk'
      fi
    ) || fail "$stage deferred husk close regression"
  done
  pass 'deferred husk cleanup preserves ownership changes while ordinary replacement completes'
}

test_published_fresh_and_rebound_launches_keep_their_binding() {
  local path stage
  for path in fresh rebound; do
    for stage in ordinary literal key; do
      (
        local dir="$TMP_ROOT/published-$path-$stage" wt proj out meta rc=0
        setup_world "$dir"
        wt="$dir/wt"; proj="$dir/project"
        fm_test_spawn_home "$FM_HOME" codex
        fm_test_spawn_brief "$FM_HOME" mine
        fm_git_worktree "$proj" "$wt" published-mine
        fm_fake_exit0 "$dir/fakebin" codex treehouse gh-axi
        fm_test_fake_tmux_spawn "$dir/fakebin"
        printf 'off\n' > "$FM_HOME/config/herdr-presentation-spaces"
        write_pane w1:p3 42 "$wt" codex
        printf '{"error":{"code":"agent_not_found"}}\n' > "$FM_FAKE_WORLD/agent-w1_p3.json"
        if [ "$path" = rebound ]; then
          write_pane w2:p2 42 "$dir/unrelated" codex
          # shellcheck disable=SC2031 # setup_world initializes state in this fixture's subshell.
          fm_write_meta "$FM_STATE_OVERRIDE/mine.meta" backend=herdr window=fmtest:w2:p2 endpoint_task_id=mine \
            "worktree=$wt" "project=$proj" kind=ship harness=codex mode=no-mistakes yolo=off \
            herdr_session=fmtest herdr_workspace_id=w2 herdr_tab_id=w2:t2 herdr_pane_id=w2:p2 \
            'herdr_process_identity=proc:43:3f2a9c1e-0000-4000-8000-0123456789ab:7100'
        fi
        prepare_reset w1:p3
        cat > "$dir/fakebin/sleep" <<'SH'
#!/usr/bin/env bash
case "${FM_RESET_STAGE:-}" in
  literal)
    if grep -q '^spawn_gen=' "$FM_STATE_OVERRIDE/mine.meta" 2>/dev/null; then "$FM_FAKE_WORLD/reset"; fi
    ;;
  key) [ ! -f "$FM_FAKE_WORLD/typed" ] || "$FM_FAKE_WORLD/reset" ;;
esac
exit 0
SH
        chmod +x "$dir/fakebin/sleep"
        # shellcheck disable=SC2031 # This fixture sets its own reset stage, independent of earlier subshells.
        export FM_RESET_STAGE=$stage
        if [ "$path" = fresh ]; then
          out=$(HERDR_SESSION=fmtest fm_test_run_spawn "$FM_HOME" "$wt" "$dir/fakebin" mine "$proj" \
            --backend herdr --mode no-mistakes --yolo off 2>&1); rc=$?
        else
          out=$(HERDR_SESSION=fmtest fm_test_run_spawn "$FM_HOME" "$wt" "$dir/fakebin" mine --relaunch 2>&1); rc=$?
        fi
        if [ "$stage" = ordinary ]; then
          [ "$rc" = 0 ] || fail "$path launch regressed: $out"
          grep -q 'w1:p3 send-keys enter' "$FM_FAKE_WORLD/inputs" || fail "$path launch did not deliver Enter"
        else
          [ "$rc" != 0 ] || fail "$path/$stage launch accepted a recycled pane"
          [ -f "$FM_FAKE_WORLD/reset-done" ] || fail "$path/$stage launch did not cross a reset"
          cmp -s "$FM_FAKE_WORLD/inputs" "$FM_FAKE_WORLD/inputs-at-reset" || fail "$path/$stage launch sent input to a foreign pane"
          [ "$(cat "$FM_FAKE_WORLD/composer-w1_p3")" = 'foreign draft' ] || fail "$path/$stage launch changed a foreign draft"
        fi
        # shellcheck disable=SC2031 # setup_world initializes state in this fixture's subshell.
        meta="$FM_STATE_OVERRIDE/mine.meta"
        [ "$stage" = ordinary ] || meta="$FM_FAKE_WORLD/meta-at-reset"
        [ "$(fm_backend_target_of_meta "$meta")" = fmtest:w1:p3 ] || fail "$path did not publish its created endpoint"
        [ "$(fm_backend_herdr_meta_value "$meta" herdr_process_identity)" = 'proc:42:3f2a9c1e-0000-4000-8000-0123456789ab:7000' ] || fail "$path published a foreign process binding"
      ) || fail "$path/$stage publication regression"
    done
  done
  for stage in owned foreign unreadable; do
    (
      setup_world "$TMP_ROOT/session-ref-$stage"
      write_pane w1:p1 42 "$FM_HOME" codex
      bind_mine
      [ "$stage" != foreign ] || write_pane w1:p1 43 "$FM_HOME" codex
      [ "$stage" != unreadable ] || rm -f "$FM_PROC_ROOT_OVERRIDE/sys/kernel/random/boot_id"
      printf '{"result":{"agent":{"agent":"codex","agent_session":{"kind":"id","value":"session-one"}}}}\n' > "$FM_FAKE_WORLD/agent-w1_p1.json"
      local out
      export FM_BACKEND_HERDR_EXPECTED_LABEL=fm-mine
      if out=$(fm_backend_herdr_pane_agent_session_ref fmtest w1:p1); then
        [ "$stage" = owned ] && [ "$out" = $'codex\tsession-one' ] || fail "$stage session reference was trusted"
      else
        [ "$stage" != owned ] || fail 'owned session-reference read regressed'
        [ -z "$out" ] && [ ! -s "$FM_FAKE_WORLD/agent-reads" ] || fail "$stage session-reference read reached the foreign or unreadable pane"
      fi
    ) || fail "$stage session-reference regression"
  done
  pass 'published fresh and rebound launches guard text, Enter, and native session reads'
}

test_proc_binding_component_loss_is_unreadable() {
  local loss
  for loss in boot stat malformed-boot malformed-stat both; do
    (
      local dir="$TMP_ROOT/component-loss-$loss" identity rc
      setup_world "$dir"
      write_pane w1:p1 42 "$FM_HOME"
      bind_mine
      fm_backend_herdr_pane_process_state() { printf agent; }
      cat > "$dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
printf 'Wed Oct  7 02:03:32 2026\n'
SH
      chmod +x "$dir/fakebin/ps"
      # shellcheck disable=SC2031 # setup_world initializes state in this fixture's subshell.
      identity=$(fm_backend_herdr_meta_value "$FM_STATE_OVERRIDE/mine.meta" herdr_process_identity)
      [ "$(fm_backend_agent_state herdr fmtest:w1:p1 fm-mine)" = alive ] || fail 'proc-bound agent was not initially alive'
      case "$loss" in
        boot) rm -f "$FM_PROC_ROOT_OVERRIDE/sys/kernel/random/boot_id" ;;
        stat) rm -f "$FM_PROC_ROOT_OVERRIDE/42/stat" ;;
        malformed-boot) printf 'not-a-boot-id\n' > "$FM_PROC_ROOT_OVERRIDE/sys/kernel/random/boot_id" ;;
        malformed-stat) printf 'unreadable stat\n' > "$FM_PROC_ROOT_OVERRIDE/42/stat" ;;
        both) rm -f "$FM_PROC_ROOT_OVERRIDE/42/stat" "$FM_PROC_ROOT_OVERRIDE/sys/kernel/random/boot_id" ;;
      esac
      [ "$(fm_backend_herdr_pane_process_identity fmtest w1:p1)" = 'ps:42:Wed Oct  7 02:03:32 2026' ] || fail "$loss did not exercise a serialization fallback"
      rc=0; fm_backend_herdr_identity_matches fmtest w1:p1 "$identity" || rc=$?
      [ "$rc" = 2 ] || fail "$loss component loss was treated as a proven mismatch"
      rc=0; fm_backend_herdr_endpoint_foreign fmtest w1:p1 fm-mine || rc=$?
      [ "$rc" = 2 ] || fail "$loss component loss declared a foreign endpoint"
      [ "$(fm_backend_agent_state herdr fmtest:w1:p1 fm-mine)" = unreadable ] || fail "$loss component loss authorized duplicate recovery"
      [ "$(fm_backend_herdr_endpoint_absence_recheck fmtest:w1:p1 fm-mine)" = unreadable ] || fail "$loss absence recheck declared the live endpoint missing"
      ! fm_backend_send_key herdr fmtest:w1:p1 Enter fm-mine || fail "$loss component loss authorized input"
      ! fm_backend_capture herdr fmtest:w1:p1 5 fm-mine || fail "$loss component loss authorized capture"
      [ ! -s "$FM_FAKE_WORLD/inputs" ] && [ ! -s "$FM_FAKE_WORLD/reads" ] || fail "$loss component loss reached an unreadable endpoint"
      write_proc "$FM_PROC_ROOT_OVERRIDE" 42 7000
      [ "$(fm_backend_agent_state herdr fmtest:w1:p1 fm-mine)" = alive ] || fail "$loss recovery of stable reads did not restore liveness"
      write_proc "$FM_PROC_ROOT_OVERRIDE" 42 7001
      rm -f "$FM_PROC_ROOT_OVERRIDE/sys/kernel/random/boot_id"
      rc=0; fm_backend_herdr_identity_matches fmtest w1:p1 "$identity" || rc=$?
      [ "$rc" = 1 ] || fail 'a readable tick mismatch was hidden by missing boot identity'
      write_proc "$FM_PROC_ROOT_OVERRIDE" 42 7000
      printf 'aaaaaaaa-0000-4000-8000-0123456789ab\n' > "$FM_PROC_ROOT_OVERRIDE/sys/kernel/random/boot_id"
      rm -f "$FM_PROC_ROOT_OVERRIDE/42/stat"
      rc=0; fm_backend_herdr_identity_matches fmtest w1:p1 "$identity" || rc=$?
      [ "$rc" = 1 ] || fail 'a readable boot mismatch was hidden by missing start ticks'
      write_pane w1:p1 43 "$FM_HOME"
      rm -f "$FM_PROC_ROOT_OVERRIDE/sys/kernel/random/boot_id"
      rc=0; fm_backend_herdr_identity_matches fmtest w1:p1 "$identity" || rc=$?
      [ "$rc" = 1 ] || fail 'a readable PID mismatch was hidden by missing stable components'
    ) || fail "$loss stable-component regression"
  done
  pass 'proc component loss is unreadable unless another recorded component proves a mismatch'
}

test_native_push_validates_selected_task_ownership() {
  local path ownership status
  for path in level stream; do
    for ownership in owned foreign unreadable; do
      for status in blocked working; do
        (
          local dir="$TMP_ROOT/push-$path-$ownership-$status" state marker out rc=0 level
          setup_world "$dir"
          write_pane w1:p1 42 "$FM_HOME"
          bind_mine
          state="$dir/child/state"; mkdir -p "$state"
          # shellcheck disable=SC2031 # setup_world initializes state in this fixture's subshell.
          cp "$FM_STATE_OVERRIDE/mine.meta" "$state/a.meta"
          # shellcheck disable=SC2031 # setup_world initializes state in this fixture's subshell.
          cp "$FM_STATE_OVERRIDE/other.meta" "$state/b.meta"
          if [ "$ownership" = foreign ]; then
            # A third process owns the recycled address, so neither claiming record is bound to it.
            write_proc "$FM_PROC_ROOT_OVERRIDE" 44 7200
            write_pane w1:p1 44 "$FM_HOME"
            # shellcheck disable=SC2031 # setup_world initializes state in this fixture's subshell.
            cp "$FM_STATE_OVERRIDE/other.meta" "$FM_STATE_OVERRIDE/mine.meta"
          elif [ "$ownership" = unreadable ]; then
            rm -f "$FM_PROC_ROOT_OVERRIDE/sys/kernel/random/boot_id"
          fi
          marker=$(fm_backend_herdr_escalation_marker "$state" fmtest:w1:p1)
          if [ "$status" = working ]; then printf 'retained-marker\n' > "$marker"; fi
          level=$status; [ "$path" != stream ] || level=idle
          jq -n --arg status "$level" '{result:{agent:{agent:"pi",agent_status:$status}}}' > "$FM_FAKE_WORLD/agent-w1_p1.json"
          : > "$dir/edges"
          [ "$path" != stream ] || printf 'w1:p1\tw1\t%s\tpi\n' "$status" > "$dir/edges"
          cat > "$dir/reader" <<'SH'
#!/usr/bin/env bash
printf '@subscribed\n'
cat "$FM_STREAM_EDGES"
SH
          chmod +x "$dir/reader"
          # shellcheck disable=SC2030,SC2031 # each case runs in its own subshell fixture.
          export FM_BACKEND_HERDR_EVENT_READER="$dir/reader" FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED=1 FM_STREAM_EDGES="$dir/edges"
          out=$(fm_backend_herdr_wait_transition fmtest 0 "$state" fmtest:w1:p1) || rc=$?
          if [ "$ownership" = owned ] && [ "$status" = blocked ]; then
            [ "$rc" = 0 ] && [ "$(fm_transition_to_status "$out")" = blocked ] || fail "$path owned push did not surface blocked"
            [ ! -e "$marker" ] || fail 'detection prematurely committed the marker'
            fm_backend_herdr_commit_transition "$state" fmtest "$out"
            [ -e "$marker" ] || fail 'ordinary handled push could not commit its marker'
          else
            [ "$rc" = 1 ] && [ -z "$out" ] || fail "$path/$ownership/$status produced an unauthorized transition: $out"
            if [ "$status" = working ]; then
              if [ "$ownership" = owned ]; then
                [ ! -e "$marker" ] || fail "$path owned working transition did not clear its marker"
              else
                [ "$(cat "$marker")" = retained-marker ] || fail "$path/$ownership transition changed the selected task's marker"
              fi
            else
              [ ! -e "$marker" ] || fail "$path/$ownership transition wrote a dedupe marker"
            fi
          fi
        ) || fail "$path/$ownership/$status native push regression"
      done
    done
  done
  pass 'native reconnect levels and stream edges validate the selected home before wakes or marker changes'
}

test_failed_treehouse_return_does_not_fall_back_to_deleting_a_foreign_worktree() {
  (
    local dir="$TMP_ROOT/return-fallback" wt proj state mate out
    setup_world "$dir"
    wt="$dir/wt"; proj="$dir/project"
    # shellcheck disable=SC2031 # setup_world initializes state in this fixture's subshell.
    state="$FM_STATE_OVERRIDE"
    fm_git_worktree "$proj" "$wt" return-fallback
    mkdir -p "$FM_HOME/data" "$FM_HOME/config" "$dir/user-home"
    write_pane w1:p1 42 "$wt"
    mate="$dir/mate"; mkdir -p "$mate/state" "$mate/data" "$mate/config"
    printf 'mine\n' > "$mate/.fm-secondmate-home"
    write_pane w1:p2 43 "$mate"
    fm_write_meta "$state/mine.meta" backend=herdr window=fmtest:w1:p2 endpoint_task_id=mine \
      "worktree=$mate" "project=$mate" "home=$mate" kind=secondmate harness=pi mode=secondmate yolo=off \
      herdr_session=fmtest herdr_workspace_id=w1 herdr_tab_id=w1:t2 herdr_pane_id=w1:p2 \
      'herdr_process_identity=proc:43:3f2a9c1e-0000-4000-8000-0123456789ab:7100'
    fm_write_meta "$mate/state/leaf.meta" backend=herdr window=fmtest:w1:p1 endpoint_task_id=leaf \
      "worktree=$wt" "project=$proj" kind=scout harness=pi \
      herdr_session=fmtest herdr_workspace_id=w1 herdr_tab_id=w1:t1 herdr_pane_id=w1:p1 \
      'herdr_process_identity=proc:42:3f2a9c1e-0000-4000-8000-0123456789ab:7000'
    prepare_reset w1:p1
    fm_fake_exit0 "$dir/fakebin" lsof
    # The return fails for a reason other than a git lock, and a session reset
    # hands the recycled pane to a foreign process in the same worktree before
    # the fallback would delete the directory.
    cat > "$dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_WORLD/returns"
"$FM_FAKE_WORLD/reset"
echo 'error: treehouse could not return this worktree' >&2
exit 1
SH
    chmod +x "$dir/fakebin/treehouse"
    out=$(FM_RESET_CWD="$wt" FM_CLOSE_REMOVES=1 HOME="$dir/user-home" FM_ROOT_OVERRIDE="$FM_HOME" \
      "$ROOT/bin/fm-teardown.sh" mine --force 2>&1) && fail 'cleanup accepted a foreign pane after a failed return'
    assert_contains "$out" 'foreign herdr' 'the fallback did not identify foreign ownership'
    [ -f "$FM_FAKE_WORLD/reset-done" ] || fail 'the failed return never reached the reset'
    [ -d "$wt" ] && [ -f "$mate/state/leaf.meta" ] && [ -f "$FM_FAKE_WORLD/pane-w1_p1.json" ] \
      || fail 'the fallback deleted the worktree, its record, or the foreign pane'
  ) || fail 'failed Treehouse return fallback regression'
  pass 'a failed Treehouse return does not fall back to deleting a worktree a foreign pane now uses'
}

test_push_event_accepts_the_bound_record_behind_a_stale_one() {
  local event_path order
  for event_path in level stream; do
    for order in stale-first bound-first both-stale; do
      (
        local dir="$TMP_ROOT/push-order-$event_path-$order" state marker out rc=0 bound_task='' stale_task level=blocked size
        setup_world "$dir"
        write_pane w1:p1 42 "$FM_HOME"
        bind_mine
        state="$dir/child/state"; mkdir -p "$state"
        # shellcheck disable=SC2031 # setup_world initializes state in this fixture's subshell.
        case "$order" in
          stale-first) cp "$FM_STATE_OVERRIDE/other.meta" "$state/a.meta"; cp "$FM_STATE_OVERRIDE/mine.meta" "$state/b.meta"; bound_task=b; stale_task=a ;;
          bound-first) cp "$FM_STATE_OVERRIDE/mine.meta" "$state/a.meta"; cp "$FM_STATE_OVERRIDE/other.meta" "$state/b.meta"; bound_task=a; stale_task=b ;;
          both-stale) cp "$FM_STATE_OVERRIDE/other.meta" "$state/a.meta"; cp "$FM_STATE_OVERRIDE/other.meta" "$state/b.meta"; stale_task=a ;;
        esac
        printf 'paused: waiting on an upstream release\n' > "$state/$stale_task.status"
        [ -z "$bound_task" ] || printf 'blocked: approval needed\n' > "$state/$bound_task.status"
        # shellcheck disable=SC2030,SC2031 # Each subshell fixture intentionally selects its own state directory.
        export FM_STATE_OVERRIDE="$state"
        . "$ROOT/bin/fm-push-transition-lib.sh"
        wake() { printf '%s\n' "$1" >> "$STATE/wakes"; }
        marker=$(fm_backend_herdr_escalation_marker "$state" fmtest:w1:p1)
        [ "$event_path" != stream ] || level=idle
        jq -n --arg status "$level" '{result:{agent:{agent:"pi",agent_status:$status}}}' > "$FM_FAKE_WORLD/agent-w1_p1.json"
        : > "$dir/edges"
        [ "$event_path" != stream ] || printf 'w1:p1\tw1\tblocked\tpi\n' > "$dir/edges"
        cat > "$dir/reader" <<'SH'
#!/usr/bin/env bash
printf '@subscribed\n'
cat "$FM_STREAM_EDGES"
SH
        chmod +x "$dir/reader"
        # shellcheck disable=SC2030,SC2031 # each case runs in its own subshell fixture.
        export FM_BACKEND_HERDR_EVENT_READER="$dir/reader" FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED=1 FM_STREAM_EDGES="$dir/edges"
        out=$(fm_backend_wait_transition herdr fmtest 0 "$state" fmtest:w1:p1) || rc=$?
        [ ! -e "$marker" ] || fail "$event_path/$order: detection prematurely committed the marker"
        if [ "$order" = both-stale ]; then
          [ "$rc" = 1 ] && [ -z "$out" ] || fail 'a pane bound to neither record produced a transition'
          handle_push_transition herdr fmtest "$(fm_transition_record w1:p1 w1 '' blocked pi)"
          [ ! -e "$marker" ] && [ ! -e "$state/wakes" ] && [ ! -e "$state/.wake-queue" ] \
            || fail "$event_path/$order: handling accepted a pane bound to neither record"
        else
          [ "$rc" = 0 ] && [ "$(fm_transition_to_status "$out")" = blocked ] || fail "$event_path/$order: the correctly bound record's blocked alert was dropped"
          handle_push_transition herdr fmtest "$out"
          assert_contains "$(cat "$state/wakes")" 'herdr: agent blocked' "$event_path/$order: the bound task did not wake the supervisor"
          assert_contains "$(cat "$state/.wake-queue")" 'fmtest:w1:p1' "$event_path/$order: the bound task did not enqueue its alert"
          [ -e "$marker" ] || fail "$event_path/$order: handling did not commit the escalation marker"
          size=$(wc -c < "$state/$bound_task.status" | tr -d '[:space:]')
          [ "$(hb_surfaced_offset "$bound_task")" = "$size" ] || fail "$event_path/$order: handling did not mark the bound task's status surfaced"
          [ ! -e "$(_hb_surfaced_path "$stale_task")" ] || fail "$event_path/$order: handling marked the stale task's status surfaced"
          [ ! -e "$state/.watch-triage.log" ] || fail "$event_path/$order: the stale pause absorbed the bound task's alert"
        fi
      ) || fail "$event_path/$order push ordering regression"
    done
  done
  pass 'reconnect and stream push handling uses the bound claimant for waits, wakes, dedupe, and status bookkeeping'
}

test_secondmate_recovery_keeps_task_selection_across_lock_wait() {
  (
    local dir="$TMP_ROOT/secondmate-lock-reset"
    setup_world "$dir"
    . "$ROOT/bin/fm-env-lib.sh"
    . "$ROOT/bin/fm-secondmate-liveness-lib.sh"
    # shellcheck disable=SC2031 # setup_world initializes state in this fixture's subshell.
    STATE=$FM_STATE_OVERRIDE
    write_pane w1:p1 42 "$FM_HOME"
    printf '{"error":{"code":"agent_not_found"}}\n' > "$FM_FAKE_WORLD/agent-w1_p1.json"
    fm_write_meta "$STATE/b.meta" backend=herdr window=fmtest:w1:p1 kind=secondmate harness=pi \
      'herdr_process_identity=proc:42:3f2a9c1e-0000-4000-8000-0123456789ab:7000'
    fm_secondmate_liveness_probe "$STATE/b.meta" b poll
    [ "$FM_SM_LIVE_STATE" = dead ] && [ "$FM_SM_LIVE_KILL" = 1 ] || fail 'the original owned secondmate shell was not eligible for cleanup'
    FM_ROOT="$dir/runner"
    mkdir -p "$FM_ROOT/bin"
    cat > "$FM_ROOT/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$FM_FAKE_WORLD/relaunch"
SH
    chmod +x "$FM_ROOT/bin/fm-spawn.sh"
    # shellcheck disable=SC2031 # This fixture sets its own close behavior, independent of earlier subshells.
    export FM_CLOSE_REMOVES=1
    fm_backend_herdr_presentation_session_lock_path() { printf '%s/lock' "$FM_FAKE_WORLD"; }
    fm_lock_try_acquire() {
      [ -f "$FM_FAKE_WORLD/reset-during-lock" ] || return 1
      : > "$FM_FAKE_WORLD/lock-acquired"
    }
    fm_lock_release() { : > "$FM_FAKE_WORLD/lock-released"; }
    sleep() {
      write_pane w1:p1 43 "$FM_HOME"
      fm_write_meta "$STATE/c.meta" backend=herdr window=fmtest:w1:p1 kind=secondmate harness=pi \
        'herdr_process_identity=proc:43:3f2a9c1e-0000-4000-8000-0123456789ab:7100'
      : > "$FM_FAKE_WORLD/reset-during-lock"
    }
    fm_secondmate_liveness_relaunch "$STATE/b.meta" b || fail 'recovery did not reach its relaunch after skipping the foreign close'
    [ -f "$FM_FAKE_WORLD/lock-acquired" ] && [ -f "$FM_FAKE_WORLD/lock-released" ] || fail 'recovery did not cross and release the presentation lock'
    [ -f "$FM_FAKE_WORLD/pane-w1_p1.json" ] && [ ! -s "$FM_FAKE_WORLD/inputs" ] || fail 'recovery borrowed the competing task binding and closed its pane'
    [ "$(fm_backend_herdr_pane_shell_pid fmtest w1:p1)" = 43 ] || fail 'recovery removed the replacement shell'
    ! fm_backend_herdr_endpoint_foreign fmtest w1:p1 fm-c || fail 'the competing task no longer owns the replacement pane'
    [ "$(cat "$FM_FAKE_WORLD/relaunch")" = 'b --secondmate' ] || fail 'recovery relaunched the wrong task'
  ) || fail 'secondmate task-selection lock-wait regression'
  pass 'secondmate recovery cannot borrow a competing binding after a reset during lock acquisition'
}

test_dispatch_boundaries
test_submit_boundaries
test_identity_requires_boot_and_ticks
test_teardown_preserves_foreign_processes
test_projection_recovery_ignores_only_bound_foreign_panes
test_ordinary_teardown_and_projected_restart
test_adopted_relaunch_keeps_its_previous_binding
test_close_fallback_rechecks_the_selected_binding
test_treehouse_return_retry_rechecks_ownership
test_deferred_husk_close_rechecks_ownership
test_published_fresh_and_rebound_launches_keep_their_binding
test_proc_binding_component_loss_is_unreadable
test_native_push_validates_selected_task_ownership
test_failed_treehouse_return_does_not_fall_back_to_deleting_a_foreign_worktree
test_push_event_accepts_the_bound_record_behind_a_stale_one
test_secondmate_recovery_keeps_task_selection_across_lock_wait
