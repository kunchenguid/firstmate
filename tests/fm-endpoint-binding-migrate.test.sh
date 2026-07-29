#!/usr/bin/env bash
# Regression coverage for cleanup-time recovery of non-tmux metadata written by
# the spawn schema immediately preceding endpoint_task_id= publication.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MIGRATE="$ROOT/bin/fm-endpoint-binding-migrate.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-endpoint-binding-migrate)

make_runtime_fakebin() {  # <dir>
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf 'herdr' >> "${FM_RUNTIME_LOG:?}"
printf ' <%s>' "$@" >> "${FM_RUNTIME_LOG:?}"
printf '\n' >> "${FM_RUNTIME_LOG:?}"
case " $* " in
  *' status --json '*)
    printf '{"client":{"protocol":16,"version":"test"},"server":{"running":true}}\n'
    ;;
  *' workspace list '*)
    if [ -n "${FM_FAKE_PROJECTION_LABEL:-}" ]; then
      printf '{"result":{"workspaces":[{"workspace_id":"parent","label":"firstmate"},{"workspace_id":"w1","label":"%s"}]}}\n' \
        "$FM_FAKE_PROJECTION_LABEL"
    elif [ "${FM_FAKE_DUPLICATE_WORKSPACE:-0}" = 1 ]; then
      printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"%s"},{"workspace_id":"w9","label":"%s"}]}}\n' \
        "${FM_FAKE_WORKSPACE_LABEL:-firstmate}" "${FM_FAKE_WORKSPACE_LABEL:-firstmate}"
    else
      printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"%s"}]}}\n' \
        "${FM_FAKE_WORKSPACE_LABEL:-firstmate}"
    fi
    ;;
  *' tab list '*)
    printf '{"result":{"tabs":[{"tab_id":"w1:t2","workspace_id":"w1","label":"%s"}]}}\n' \
      "${FM_FAKE_TASK_LABEL:-fm-task}"
    ;;
  *' pane list '*)
    printf '{"result":{"panes":[{"pane_id":"w1:p2","tab_id":"w1:t2"}]}}\n'
    ;;
  *' pane get '*)
    printf '{"result":{"pane":{"pane_id":"w1:p2","foreground_cwd":"%s"}}}\n' \
      "${FM_FAKE_FOREGROUND_CWD:-}"
    ;;
  *' pane close '*)
    printf '{"result":{"closed":true}}\n'
    ;;
  *)
    printf '{"result":{}}\n'
    ;;
esac
SH
  cat > "$fakebin/zellij" <<'SH'
#!/usr/bin/env bash
set -u
printf 'zellij' >> "${FM_RUNTIME_LOG:?}"
printf ' <%s>' "$@" >> "${FM_RUNTIME_LOG:?}"
printf '\n' >> "${FM_RUNTIME_LOG:?}"
case " $* " in
  *'list-sessions --short --no-formatting'*) printf 'firstmate\n' ;;
  *'action list-tabs --json'*)
    printf '[{"tab_id":3,"name":"%s","active":false}]\n' "${FM_FAKE_SCOPED_TITLE:-foreign}"
    ;;
  *'action list-panes --json'*)
    printf '[{"tab_id":3,"id":7,"is_plugin":false}]\n'
    ;;
  *) printf '{}\n' ;;
esac
SH
  cat > "$fakebin/cmux" <<'SH'
#!/usr/bin/env bash
set -u
printf 'cmux' >> "${FM_RUNTIME_LOG:?}"
printf ' <%s>' "$@" >> "${FM_RUNTIME_LOG:?}"
printf '\n' >> "${FM_RUNTIME_LOG:?}"
case " $* " in
  *'list-windows --json'*) printf '[{"id":"window-1"}]\n' ;;
  *'workspace list --json'*)
    printf '{"workspaces":[{"id":"workspace-1","title":"%s"}]}\n' "${FM_FAKE_SCOPED_TITLE:-foreign}"
    ;;
  *'list-panes --workspace workspace-1'*)
    printf '{"panes":[{"surface_ids":["surface-2"],"selected_surface_id":"surface-2"}]}\n'
    ;;
  *) printf '{}\n' ;;
esac
SH
  cat > "$fakebin/orca" <<'SH'
#!/usr/bin/env bash
printf 'orca' >> "${FM_RUNTIME_LOG:?}"
printf ' <%s>' "$@" >> "${FM_RUNTIME_LOG:?}"
printf '\n' >> "${FM_RUNTIME_LOG:?}"
exit 97
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/herdr" "$fakebin/zellij" "$fakebin/cmux" "$fakebin/orca" "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

make_case() {  # <name> <id>
  local name=$1 id=$2 dir home project worktree fakebin
  dir="$TMP_ROOT/$name"
  home="$dir/home"
  project="$home/projects/project"
  worktree="$dir/worktree"
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$home/projects"
  fm_git_worktree "$project" "$worktree" "fixture-$name"
  printf 'legacy task instructions\n' > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  : > "$dir/runtime.log"
  fakebin=$(make_runtime_fakebin "$dir")
  printf '%s|%s|%s|%s|%s\n' "$dir" "$home" "$project" "$worktree" "$fakebin"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR WORKTREE_DIR FAKEBIN_DIR <<EOF_CASE
$1
EOF_CASE
}

write_legacy_common() {  # <meta> <id> <window> <backend> [backend-fields...]
  local meta=$1 id=$2 window=$3 backend=$4
  shift 4
  fm_write_meta "$meta" \
    "window=$window" \
    "worktree=$WORKTREE_DIR" \
    "project=$PROJECT_DIR" \
    'harness=pi' \
    'kind=scout' \
    'mode=no-mistakes' \
    'yolo=off' \
    "tasktmp=/tmp/fm-$id" \
    'model=default' \
    'effort=default' \
    "backend=$backend" \
    "$@"
}

write_legacy_herdr() {  # <meta> <id>
  write_legacy_common "$1" "$2" 'default:w1:p2' herdr \
    'herdr_session=default' \
    'herdr_workspace_id=w1' \
    'herdr_tab_id=w1:t2' \
    'herdr_pane_id=w1:p2'
}

write_legacy_zellij() {  # <meta> <id>
  write_legacy_common "$1" "$2" 'firstmate:7' zellij \
    'zellij_session=firstmate' \
    'zellij_tab_id=3' \
    'zellij_pane_id=7'
}

write_legacy_cmux() {  # <meta> <id>
  write_legacy_common "$1" "$2" 'workspace-1:surface-2' cmux \
    'cmux_workspace_id=workspace-1' \
    'cmux_surface_id=surface-2'
}

write_legacy_orca() {  # <meta> <id>
  write_legacy_common "$1" "$2" "fm-$2" orca \
    'orca_worktree_id=worktree-9' \
    'terminal=terminal-7'
}

run_migrate() {  # <id>
  local id=$1
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    FM_RUNTIME_LOG="$CASE_DIR/runtime.log" \
    FM_FAKE_FOREGROUND_CWD="$WORKTREE_DIR" \
    FM_FAKE_TASK_LABEL="fm-$id" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$MIGRATE" "$id"
}

scoped_zellij_title() {  # <id>
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    bash -c '. "$1/bin/backends/zellij.sh"; fm_backend_zellij_scoped_title "fm-$2"' _ "$ROOT" "$1"
}

scoped_cmux_title() {  # <id>
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    bash -c '. "$1/bin/backends/cmux.sh"; fm_backend_cmux_scoped_title "fm-$2"' _ "$ROOT" "$1"
}

assert_unbound() {  # <meta> <description>
  ! grep -q '^endpoint_task_id=' "$1" || fail "$2 unexpectedly gained a binding"
}

test_cross_version_herdr_cleanup_recovers_before_ordinary_refusal() {
  local record id meta out rc
  id=legacy-herdr
  record=$(make_case cross-version-herdr "$id")
  read_case "$record"
  meta="$HOME_DIR/state/$id.meta"
  # This field order is the exact non-tmux block emitted by fm-spawn.sh at
  # fa0d85d, the parent of endpoint binding commit fbece9c.
  write_legacy_herdr "$meta" "$id"
  printf 'scratch\n' > "$WORKTREE_DIR/uncommitted"

  set +e
  out=$( FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    FM_RUNTIME_LOG="$CASE_DIR/runtime.log" \
    FM_FAKE_FOREGROUND_CWD="$WORKTREE_DIR" FM_FAKE_TASK_LABEL="fm-$id" \
    PATH="$FAKEBIN_DIR:$PATH" "$TEARDOWN" "$id" 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "cross-version teardown should still refuse the deliberately dirty worktree"
  assert_contains "$out" "ENDPOINT_BINDING_MIGRATION: task $id: exact live herdr identity bound for cleanup" \
    "teardown did not recover the old Herdr binding before its ordinary safety checks"
  assert_grep "endpoint_task_id=$id" "$meta" "cross-version teardown did not publish the recovered binding"
  assert_not_contains "$out" "lacks an exact task binding" "current teardown still exposed the compatibility refusal"
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-backend.sh"
  fm_backend_validate_task_endpoint "$meta" "$id" || fail "recovered Herdr metadata did not pass the unchanged validator"
  pass "cross-version Herdr cleanup binds exact live identity, then reaches ordinary worktree safety"
}

test_projected_herdr_identity_recovers_only_with_exact_live_topology() {
  local record id meta token label rc
  id=legacy-projection
  token=abcdefghijklmnopqrstuv
  label="└ $id · p:$token"
  record=$(make_case herdr-projection "$id")
  read_case "$record"
  meta="$HOME_DIR/state/$id.meta"
  write_legacy_herdr "$meta" "$id"
  FM_FAKE_PROJECTION_LABEL="$label" run_migrate "$id" >/dev/null \
    || fail "exact projected Herdr topology was refused"
  assert_grep "endpoint_task_id=$id" "$meta" "projected Herdr record did not gain a binding"

  id=projection-foreign-label
  token=zyxwvutsrqponmlkjihgfe
  label="└ other-task · p:$token"
  record=$(make_case herdr-projection-foreign-label "$id")
  read_case "$record"
  meta="$HOME_DIR/state/$id.meta"
  write_legacy_herdr "$meta" "$id"
  set +e
  FM_FAKE_PROJECTION_LABEL="$label" run_migrate "$id" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "foreign projected Herdr task label was accepted"
  assert_unbound "$meta" "foreign-label projected Herdr metadata"
  pass "projected Herdr migration requires its exact live task label and topology without trusting its journal"
}

test_herdr_adversarial_mismatches_remain_unbound() {
  local record id meta out rc other source_meta destination

  id=herdr-wrong-label
  record=$(make_case herdr-wrong-label "$id")
  read_case "$record"
  meta="$HOME_DIR/state/$id.meta"
  write_legacy_herdr "$meta" "$id"
  set +e
  out=$( FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$CASE_DIR/runtime.log" \
    FM_FAKE_FOREGROUND_CWD="$WORKTREE_DIR" FM_FAKE_TASK_LABEL='fm-other' \
    PATH="$FAKEBIN_DIR:$PATH" "$MIGRATE" "$id" 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "wrong Herdr task label was accepted"
  assert_contains "$out" "topology, home, task label, and worktree do not all agree" \
    "wrong Herdr label refusal was not explicit"
  assert_unbound "$meta" "wrong-label metadata"

  id=herdr-wrong-worktree
  record=$(make_case herdr-wrong-worktree "$id")
  read_case "$record"
  meta="$HOME_DIR/state/$id.meta"
  write_legacy_herdr "$meta" "$id"
  set +e
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$CASE_DIR/runtime.log" \
    FM_FAKE_FOREGROUND_CWD="$PROJECT_DIR" FM_FAKE_TASK_LABEL="fm-$id" \
    PATH="$FAKEBIN_DIR:$PATH" "$MIGRATE" "$id" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "wrong Herdr foreground worktree was accepted"
  assert_unbound "$meta" "wrong-worktree metadata"

  id=herdr-duplicate
  record=$(make_case herdr-duplicate "$id")
  read_case "$record"
  meta="$HOME_DIR/state/$id.meta"
  write_legacy_herdr "$meta" "$id"
  other="$HOME_DIR/state/copied.meta"
  cp "$meta" "$other"
  set +e
  out=$(run_migrate "$id" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "duplicate endpoint metadata was accepted"
  assert_contains "$out" "another local record references the same endpoint" \
    "duplicate endpoint refusal was not explicit"
  assert_unbound "$meta" "duplicate endpoint metadata"

  id=herdr-cross-home
  record=$(make_case herdr-cross-home "$id")
  read_case "$record"
  source_meta="$HOME_DIR/state/$id.meta"
  write_legacy_herdr "$source_meta" "$id"
  destination="$CASE_DIR/foreign-home"
  mkdir -p "$destination/state" "$destination/data/$id"
  cp "$source_meta" "$destination/state/$id.meta"
  printf 'copied instructions\n' > "$destination/data/$id/brief.md"
  set +e
  FM_HOME="$destination" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$CASE_DIR/runtime.log" \
    FM_FAKE_FOREGROUND_CWD="$WORKTREE_DIR" FM_FAKE_TASK_LABEL="fm-$id" \
    PATH="$FAKEBIN_DIR:$PATH" "$MIGRATE" "$id" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "cross-home copied Herdr metadata was accepted"
  assert_unbound "$destination/state/$id.meta" "cross-home copied metadata"

  pass "legacy Herdr migration preserves wrong-label, wrong-worktree, duplicate, and cross-home copied records"
}

test_zellij_requires_exact_home_scoped_title() {
  local record id meta title rc
  id=legacy-zellij
  record=$(make_case zellij-valid "$id")
  read_case "$record"
  meta="$HOME_DIR/state/$id.meta"
  write_legacy_zellij "$meta" "$id"
  title=$(scoped_zellij_title "$id")
  FM_FAKE_SCOPED_TITLE="$title" run_migrate "$id" >/dev/null \
    || fail "valid legacy Zellij identity was refused"
  assert_grep "endpoint_task_id=$id" "$meta" "valid Zellij record did not gain a binding"

  id=zellij-foreign
  record=$(make_case zellij-foreign "$id")
  read_case "$record"
  meta="$HOME_DIR/state/$id.meta"
  write_legacy_zellij "$meta" "$id"
  set +e
  FM_FAKE_SCOPED_TITLE='fm-foreign-home-task' run_migrate "$id" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "foreign Zellij title was accepted"
  assert_unbound "$meta" "foreign Zellij metadata"
  pass "legacy Zellij migration requires the exact home-scoped task title and recorded topology"
}

test_cmux_requires_exact_home_scoped_title_and_surface() {
  local record id meta title rc
  id=legacy-cmux
  record=$(make_case cmux-valid "$id")
  read_case "$record"
  meta="$HOME_DIR/state/$id.meta"
  write_legacy_cmux "$meta" "$id"
  title=$(scoped_cmux_title "$id")
  FM_FAKE_SCOPED_TITLE="$title" run_migrate "$id" >/dev/null \
    || fail "valid legacy cmux identity was refused"
  assert_grep "endpoint_task_id=$id" "$meta" "valid cmux record did not gain a binding"

  id=cmux-foreign
  record=$(make_case cmux-foreign "$id")
  read_case "$record"
  meta="$HOME_DIR/state/$id.meta"
  write_legacy_cmux "$meta" "$id"
  set +e
  FM_FAKE_SCOPED_TITLE='fm-foreign-home-task' run_migrate "$id" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "foreign cmux title was accepted"
  assert_unbound "$meta" "foreign cmux metadata"
  pass "legacy cmux migration requires the exact home-scoped task title and recorded surface"
}

test_orca_and_unsafe_metadata_remain_quarantined_by_refusal() {
  local record id meta out rc hardlink
  id=legacy-orca
  record=$(make_case orca-refused "$id")
  read_case "$record"
  meta="$HOME_DIR/state/$id.meta"
  write_legacy_orca "$meta" "$id"
  set +e
  out=$(run_migrate "$id" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "legacy Orca record was accepted without a terminal-to-worktree proof"
  assert_contains "$out" "Orca has no verified read-only terminal-to-named-worktree identity proof" \
    "Orca refusal did not name its missing proof"
  assert_unbound "$meta" "legacy Orca metadata"
  [ ! -s "$CASE_DIR/runtime.log" ] || fail "Orca migration invoked the unverified runtime API"

  id=hardlinked-herdr
  record=$(make_case hardlinked-herdr "$id")
  read_case "$record"
  meta="$HOME_DIR/state/$id.meta"
  write_legacy_herdr "$meta" "$id"
  hardlink="$CASE_DIR/copied.meta"
  ln "$meta" "$hardlink"
  set +e
  run_migrate "$id" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "hard-linked legacy metadata was accepted"
  assert_unbound "$meta" "hard-linked metadata"

  id=legacy-secondmate
  record=$(make_case secondmate-refused "$id")
  read_case "$record"
  meta="$HOME_DIR/state/$id.meta"
  write_legacy_herdr "$meta" "$id"
  perl -pi -e 's/^kind=scout$/kind=secondmate/' "$meta"
  set +e
  run_migrate "$id" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "legacy secondmate metadata was accepted without parent-to-home provenance"
  assert_unbound "$meta" "legacy secondmate metadata"
  pass "legacy Orca, secondmate, and unsafe copied file identities remain preserved and refused"
}

test_cross_version_herdr_cleanup_recovers_before_ordinary_refusal
test_projected_herdr_identity_recovers_only_with_exact_live_topology
test_herdr_adversarial_mismatches_remain_unbound
test_zellij_requires_exact_home_scoped_title
test_cmux_requires_exact_home_scoped_title_and_surface
test_orca_and_unsafe_metadata_remain_quarantined_by_refusal

echo "# all endpoint binding migration tests passed"
