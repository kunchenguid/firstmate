#!/usr/bin/env bash
# Regression coverage for cleanup-time recovery of non-tmux metadata written by
# the spawn schema immediately preceding endpoint_task_id= publication.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MIGRATE="$ROOT/bin/fm-endpoint-binding-migrate.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
UPDATE="$ROOT/bin/fm-update.sh"
TMP_ROOT=$(fm_test_tmproot fm-endpoint-binding-migrate)

# Deterministic identity for the fixture commits the updater leg fast-forwards.
fm_git_identity fmtest fmtest@example.invalid

# --- the legacy schema, taken from history rather than restated ---------------
#
# The fixtures below must stay the record the pre-binding spawn really wrote.
# resolve_prebinding_spawn_ref finds that spawn script by content (the last one
# that does not publish endpoint_task_id=), exactly like the historical tmux
# adapter fixture in tests/fm-backend.test.sh, so a squash or rebase cannot
# quietly turn the baseline into HEAD.

resolve_prebinding_spawn_ref() {
  local commit body
  while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    body=$(git -C "$ROOT" show "$commit:bin/fm-spawn.sh" 2>/dev/null) || continue
    case "$body" in
      *'endpoint_task_id='*) continue ;;
    esac
    printf '%s\n' "$commit"
    return 0
  done < <(git -C "$ROOT" log --first-parent --format='%H' HEAD -- bin/fm-spawn.sh)
  return 1
}

# The exact task-record block that historical spawn script emitted.
historical_spawn_meta_block() {  # <ref>
  local body close open
  body=$(git -C "$ROOT" show "$1:bin/fm-spawn.sh") || return 1
  close=$(printf '%s\n' "$body" | grep -n '^} > "\$STATE/\$ID\.meta"' | head -1 | cut -d: -f1)
  [ -n "$close" ] || return 1
  open=$(printf '%s\n' "$body" | head -n "$close" | grep -n '^{$' | tail -1 | cut -d: -f1)
  [ -n "$open" ] || return 1
  [ "$open" -lt "$close" ] || return 1
  printf '%s\n' "$body" | sed -n "$((open + 1)),$((close - 1))p"
}

# The keys that block emitted for one backend, in order.
historical_spawn_meta_keys() {  # <ref> <backend>
  local block
  block=$(historical_spawn_meta_block "$1") || return 1
  printf '%s\n' "$block" | awk -v backend="$2" '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*if \[ "\$BACKEND" = [a-z]+ \]; then$/ {
      gate = $0
      sub(/^.*= /, "", gate)
      sub(/ \].*$/, "", gate)
      next
    }
    /^[[:space:]]*if \[ "\$KIND" = secondmate \]; then$/ { gate = "secondmate"; next }
    /^[[:space:]]*fi$/ { gate = ""; next }
    /^[[:space:]]*\[ "\$BACKEND" = tmux \] \|\| echo "backend=/ {
      if (backend != "tmux") print "backend"
      next
    }
    /echo "[a-z_]+=/ {
      if (gate != "" && gate != backend) next
      key = $0
      sub(/^[^"]*"/, "", key)
      sub(/=.*$/, "", key)
      print key
    }
  '
}

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
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf 'tmux' >> "${FM_RUNTIME_LOG:?}"
printf ' <%s>' "$@" >> "${FM_RUNTIME_LOG:?}"
printf '\n' >> "${FM_RUNTIME_LOG:?}"
exit 0
SH
  chmod +x "$fakebin/herdr" "$fakebin/zellij" "$fakebin/cmux" "$fakebin/orca" "$fakebin/treehouse" "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

make_case() {  # <name> <id> [project-dir]
  local name=$1 id=$2 dir home project worktree fakebin
  dir="$TMP_ROOT/$name"
  home="$dir/home"
  project=${3:-$home/projects/project}
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

# The one place the legacy record is described, in the historical field order.
# test_legacy_fixture_matches_historical_spawn_schema proves this key order is
# still exactly what the pre-binding fm-spawn.sh wrote, for every backend.
legacy_fields() {  # <id> <backend>
  local id=$1 backend=$2 window
  case "$backend" in
    herdr) window='default:w1:p2' ;;
    zellij) window='firstmate:7' ;;
    cmux) window='workspace-1:surface-2' ;;
    orca) window="fm-$id" ;;
    *) return 1 ;;
  esac
  printf '%s\n' \
    "window=$window" \
    "worktree=${WORKTREE_DIR:-}" \
    "project=${PROJECT_DIR:-}" \
    'harness=pi' \
    'kind=scout' \
    'mode=no-mistakes' \
    'yolo=off' \
    "tasktmp=/tmp/fm-$id" \
    'model=default' \
    'effort=default' \
    "backend=$backend"
  case "$backend" in
    herdr)
      printf '%s\n' \
        'herdr_session=default' \
        'herdr_workspace_id=w1' \
        'herdr_tab_id=w1:t2' \
        'herdr_pane_id=w1:p2'
      ;;
    zellij)
      printf '%s\n' \
        'zellij_session=firstmate' \
        'zellij_tab_id=3' \
        'zellij_pane_id=7'
      ;;
    orca)
      printf '%s\n' \
        'orca_worktree_id=worktree-9' \
        'terminal=terminal-7'
      ;;
    cmux)
      printf '%s\n' \
        'cmux_workspace_id=workspace-1' \
        'cmux_surface_id=surface-2'
      ;;
  esac
}

write_legacy_meta() {  # <meta> <id> <backend>
  local meta=$1 fields=() line
  while IFS= read -r line; do
    fields+=("$line")
  done < <(legacy_fields "$2" "$3")
  [ "${#fields[@]}" -gt 0 ] || fail "no legacy fields for backend $3"
  fm_write_meta "$meta" "${fields[@]}"
}

write_legacy_herdr() {  # <meta> <id>
  write_legacy_meta "$1" "$2" herdr
}

write_legacy_zellij() {  # <meta> <id>
  write_legacy_meta "$1" "$2" zellij
}

write_legacy_cmux() {  # <meta> <id>
  write_legacy_meta "$1" "$2" cmux
}

write_legacy_orca() {  # <meta> <id>
  write_legacy_meta "$1" "$2" orca
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

# Runs a command with a wall-clock budget so a runaway recursion fails this
# suite instead of hanging it. Returns 124 when the budget is exhausted.
run_with_deadline() {  # <seconds> <output-file> <command...>
  local deadline=$1 out_file=$2 pid waited=0 rc
  shift 2
  "$@" > "$out_file" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$deadline" ]; then
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid"
  rc=$?
  return "$rc"
}

herdr_workspace_label_for_home() {  # <home>
  FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" \
    bash -c '. "$1/bin/backends/herdr.sh"; fm_backend_herdr_workspace_label' _ "$ROOT"
}

# A fast-forwardable firstmate repo: a bare origin one commit ahead of the
# clone, so a real fm-update.sh run has something to advance. Echoes the clone.
seed_updatable_root() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  git init -q --bare "$dir/origin.git"
  git -C "$dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$dir/origin.git" "$dir/seed" 2>/dev/null
  printf 'v1\n' > "$dir/seed/AGENTS.md"
  git -C "$dir/seed" add -A
  git -C "$dir/seed" commit -qm c1
  git -C "$dir/seed" push -q origin main
  git clone -q "$dir/origin.git" "$dir/main"
  git -C "$dir/main" remote set-head origin main >/dev/null 2>&1 || true
  printf 'v2\n' > "$dir/seed/AGENTS.md"
  git -C "$dir/seed" add -A
  git -C "$dir/seed" commit -qm c2
  git -C "$dir/seed" push -q origin main
  printf '%s\n' "$dir/main"
}

assert_unbound() {  # <meta> <description>
  ! grep -q '^endpoint_task_id=' "$1" || fail "$2 unexpectedly gained a binding"
}

test_legacy_fixture_matches_historical_spawn_schema() {
  local ref head backend expected actual
  head=$(git -C "$ROOT" rev-parse HEAD)
  ref=$(resolve_prebinding_spawn_ref) \
    || fail "unable to locate a historical bin/fm-spawn.sh that predates endpoint_task_id="
  [ "$ref" != "$head" ] \
    || fail "pre-binding spawn baseline collapsed to HEAD; the fixture is no longer historical"
  case "$(git -C "$ROOT" show "$ref:bin/fm-spawn.sh")" in
    *'endpoint_task_id='*) fail "resolve_prebinding_spawn_ref returned a spawn script that already binds" ;;
  esac
  grep -q 'endpoint_task_id=\$ID' "$ROOT/bin/fm-spawn.sh" \
    || fail "current fm-spawn.sh no longer publishes the endpoint binding this migration exists to backfill"

  # WORKTREE_DIR/PROJECT_DIR only supply values; the schema under test is the key order.
  for backend in herdr zellij cmux orca; do
    expected=$(historical_spawn_meta_keys "$ref" "$backend") \
      || fail "could not extract the historical $backend record shape from $ref"
    [ -n "$expected" ] || fail "historical $backend record shape at $ref came back empty"
    actual=$(legacy_fields "schema-probe" "$backend" | cut -d= -f1)
    [ "$expected" = "$actual" ] \
      || fail "legacy $backend fixture drifted from the historical spawn schema at $ref"$'\n'"expected:"$'\n'"$expected"$'\n'"actual:"$'\n'"$actual"
  done
  pass "legacy fixtures still match the exact pre-binding spawn record shape taken from history"
}

test_cross_version_herdr_cleanup_recovers_before_ordinary_refusal() {
  local record id meta out rc update_root before
  id=legacy-herdr
  record=$(make_case cross-version-herdr "$id")
  read_case "$record"
  meta="$HOME_DIR/state/$id.meta"
  # Leg 1: the record the pre-binding spawn schema wrote, in that exact shape
  # (test_legacy_fixture_matches_historical_spawn_schema binds it to history).
  write_legacy_herdr "$meta" "$id"

  # Leg 2: a real fast-forward self-update over that live home. The updater
  # advances tracked files only, so the operational record must survive byte for
  # byte, still unbound - that is what leaves the home cross-version broken.
  update_root=$(seed_updatable_root "$CASE_DIR/update")
  before=$(cat "$meta")
  out=$(FM_ROOT_OVERRIDE="$update_root" FM_HOME="$HOME_DIR" "$UPDATE" 2>/dev/null) \
    || fail "fast-forward self-update failed over the legacy home"
  assert_contains "$out" "firstmate: updated" "the update leg did not actually fast-forward anything"
  [ "$(cat "$meta")" = "$before" ] || fail "self-update rewrote the operational task record"
  assert_unbound "$meta" "the legacy record after self-update"

  # Leg 3: current cleanup, on the updated home.
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

test_external_project_recovery_needs_exact_replay_safe_authorization() {
  local record_a record_b id_a id_b meta_a meta_b out rc allow_line
  id_a=external-project
  id_b=external-project-replay
  record_a=$(make_case external-project "$id_a" "$TMP_ROOT/external-repos/repo-a")
  read_case "$record_a"
  meta_a="$HOME_DIR/state/$id_a.meta"
  write_legacy_herdr "$meta_a" "$id_a"
  set +e
  out=$(run_migrate "$id_a" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a project outside this home was recovered with no explicit authorization"
  assert_contains "$out" "recorded project is outside this firstmate home and this exact record is not authorized" \
    "out-of-home refusal did not name the authorization it wants"
  assert_unbound "$meta_a" "unauthorized out-of-home metadata"
  allow_line=$(printf '%s\n' "$out" | sed -n 's/.*by the line "\(.*\)".*/\1/p' | head -1)
  [ -n "$allow_line" ] || fail "refusal did not print the exact authorization line to add"

  # The same authorization line does not travel to any other record.
  record_b=$(make_case external-project-replay "$id_b" "$TMP_ROOT/external-repos/repo-b")
  read_case "$record_b"
  meta_b="$HOME_DIR/state/$id_b.meta"
  write_legacy_herdr "$meta_b" "$id_b"
  printf '%s\n' "$allow_line" > "$HOME_DIR/config/endpoint-binding-recovery-allow"
  chmod 600 "$HOME_DIR/config/endpoint-binding-recovery-allow"
  set +e
  out=$(run_migrate "$id_b" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an authorization for another record recovered this one"
  assert_contains "$out" "is not authorized" "replayed authorization refusal was not explicit"
  assert_unbound "$meta_b" "metadata under a replayed authorization"

  # The same record needs no authorization at all once FM_PROJECTS_OVERRIDE, the
  # documented projects-dir override every sibling script honors, contains it.
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_PROJECTS_OVERRIDE="$TMP_ROOT/external-repos" \
    FM_RUNTIME_LOG="$CASE_DIR/runtime.log" FM_FAKE_FOREGROUND_CWD="$WORKTREE_DIR" \
    FM_FAKE_TASK_LABEL="fm-$id_b" PATH="$FAKEBIN_DIR:$PATH" "$MIGRATE" "$id_b" >/dev/null \
    || fail "a project inside FM_PROJECTS_OVERRIDE was still treated as outside this home"
  assert_grep "endpoint_task_id=$id_b" "$meta_b" "override-contained project did not gain a binding"

  read_case "$record_a"
  printf '%s\n' "$allow_line" > "$HOME_DIR/config/endpoint-binding-recovery-allow"
  chmod 600 "$HOME_DIR/config/endpoint-binding-recovery-allow"
  run_migrate "$id_a" >/dev/null || fail "the exact authorization for this record was refused"
  assert_grep "endpoint_task_id=$id_a" "$meta_a" "authorized out-of-home record did not gain a binding"

  # The lingering authorization re-opens nothing: the bound record is done.
  set +e
  out=$(run_migrate "$id_a" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a bound record was migrated again under a lingering authorization"
  assert_contains "$out" "endpoint binding is already present or ambiguous" \
    "re-run refusal on an already bound record was not explicit"
  pass "out-of-home project recovery honors FM_PROJECTS_OVERRIDE and otherwise needs one exact record-pinned authorization that cannot be replayed"
}

test_secondmate_force_retirement_preflights_child_bindings() {
  local dir home subhome childproj childwt childid fakebin label out rc
  dir="$TMP_ROOT/secondmate-preflight"
  home="$dir/home"
  subhome="$dir/subhome"
  childid=legacy-child
  childproj="$subhome/projects/alpha"
  # Deliberately inside the retiring parent's own home, so child validation
  # refuses AFTER the preflight and nothing is destroyed by this test.
  childwt="$home/child-worktree"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" \
    "$subhome/state" "$subhome/data/$childid" "$subhome/config" "$subhome/projects"
  touch "$home/state/.last-watcher-beat" "$subhome/state/.last-watcher-beat"
  : > "$dir/runtime.log"
  fakebin=$(make_runtime_fakebin "$dir")
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  fm_git_worktree "$childproj" "$childwt" secondmate-child
  printf 'legacy child instructions\n' > "$subhome/data/$childid/brief.md"
  fm_write_meta "$home/state/domain.meta" \
    'window=firstmate:fm-domain' \
    "worktree=$subhome" \
    "project=$subhome" \
    'harness=echo' \
    'kind=secondmate' \
    'mode=secondmate' \
    'yolo=off' \
    "home=$subhome" \
    'projects=alpha'
  printf '%s\n' \
    "- domain - design domain (home: $subhome; scope: design domain; projects: alpha; added 2026-06-22)" \
    > "$home/data/secondmates.md"
  WORKTREE_DIR=$childwt
  PROJECT_DIR=$childproj
  write_legacy_herdr "$subhome/state/$childid.meta" "$childid"
  label=$(herdr_workspace_label_for_home "$subhome")
  [ "$label" != firstmate ] || fail "secondmate home did not scope its own herdr workspace label"

  set +e
  out=$( FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$dir/runtime.log" \
    FM_FAKE_WORKSPACE_LABEL="$label" FM_FAKE_TASK_LABEL="fm-$childid" \
    FM_FAKE_FOREGROUND_CWD="$childwt" \
    PATH="$fakebin:$PATH" "$TEARDOWN" domain --force 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "force retirement should still refuse a child worktree inside the active home"
  assert_contains "$out" "ENDPOINT_BINDING_MIGRATION: task $childid: exact live herdr identity bound for cleanup" \
    "secondmate retirement did not preflight the child binding inside the child's own home"
  assert_not_contains "$out" "lacks an exact task binding" \
    "secondmate child authorization still exposed the cross-version refusal"
  assert_grep "endpoint_task_id=$childid" "$subhome/state/$childid.meta" \
    "preflight did not publish the child binding"
  assert_contains "$out" "inside the active firstmate home" \
    "child validation did not reach its ordinary removal-target refusal"
  [ -d "$subhome" ] || fail "a refused retirement removed the secondmate home"
  [ -d "$childwt" ] || fail "a refused retirement removed the child worktree"
  pass "secondmate force retirement preflights unbound child records home-scoped, then authorizes normally"
}

test_unusable_metadata_digest_refuses_before_authorizing() {
  local record id meta digest_bin tool out rc
  id=digest-unavailable
  record=$(make_case digest-unavailable "$id" "$TMP_ROOT/external-repos/repo-c")
  read_case "$record"
  meta="$HOME_DIR/state/$id.meta"
  write_legacy_herdr "$meta" "$id"
  digest_bin="$CASE_DIR/no-digest-bin"
  mkdir -p "$digest_bin"
  for tool in shasum sha256sum; do
    printf '#!/usr/bin/env bash\nexit 1\n' > "$digest_bin/$tool"
    chmod +x "$digest_bin/$tool"
  done

  set +e
  out=$( FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$CASE_DIR/runtime.log" \
    FM_FAKE_FOREGROUND_CWD="$WORKTREE_DIR" FM_FAKE_TASK_LABEL="fm-$id" \
    PATH="$digest_bin:$FAKEBIN_DIR:$PATH" "$MIGRATE" "$id" 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a record with no readable digest was migrated"
  assert_contains "$out" "metadata bytes have no well-formed digest" \
    "an unusable digest did not refuse on its own terms"
  assert_not_contains "$out" "is not authorized in" \
    "an unusable digest still offered an authorization line to paste"
  assert_unbound "$meta" "metadata whose digest could not be computed"
  pass "an unreadable or empty metadata digest refuses before it can key an authorization"
}

test_secondmate_preflight_refuses_unvalidated_nested_home() {
  local dir home subhome nestedid fakebin out rc
  dir="$TMP_ROOT/secondmate-preflight-cycle"
  home="$dir/home"
  subhome="$dir/subhome"
  nestedid=nested-domain
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" \
    "$subhome/state" "$subhome/data" "$subhome/config" "$subhome/projects"
  touch "$home/state/.last-watcher-beat" "$subhome/state/.last-watcher-beat"
  : > "$dir/runtime.log"
  fakebin=$(make_runtime_fakebin "$dir")
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  fm_write_meta "$home/state/domain.meta" \
    'window=firstmate:fm-domain' \
    "worktree=$subhome" \
    "project=$subhome" \
    'harness=echo' \
    'kind=secondmate' \
    'mode=secondmate' \
    'yolo=off' \
    "home=$subhome" \
    'projects=alpha'
  printf '%s\n' \
    "- domain - design domain (home: $subhome; scope: design domain; projects: alpha; added 2026-06-22)" \
    > "$home/data/secondmates.md"
  # A nested secondmate record naming its own home: unchecked recursion here
  # re-scans the same state dir forever instead of refusing.
  fm_write_meta "$subhome/state/$nestedid.meta" \
    "window=firstmate:fm-$nestedid" \
    "endpoint_task_id=$nestedid" \
    "worktree=$subhome" \
    "project=$subhome" \
    'harness=echo' \
    'kind=secondmate' \
    'mode=secondmate' \
    'yolo=off' \
    "home=$subhome" \
    'projects=alpha'

  set +e
  run_with_deadline 60 "$dir/teardown.out" \
    env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$fakebin:$PATH" "$TEARDOWN" domain --force
  rc=$?
  set -e
  out=$(cat "$dir/teardown.out")
  [ "$rc" -ne 124 ] || fail "secondmate retirement did not terminate on a self-referential nested home"
  [ "$rc" -ne 0 ] || fail "secondmate retirement accepted an unvalidated nested home"
  assert_contains "$out" "child firstmate home" \
    "nested home refusal did not come from the removal-safety owner"
  [ -d "$subhome" ] || fail "a refused retirement removed the secondmate home"
  pass "the secondmate preflight validates every nested home before recursing into it"
}

test_legacy_fixture_matches_historical_spawn_schema
test_cross_version_herdr_cleanup_recovers_before_ordinary_refusal
test_projected_herdr_identity_recovers_only_with_exact_live_topology
test_herdr_adversarial_mismatches_remain_unbound
test_zellij_requires_exact_home_scoped_title
test_cmux_requires_exact_home_scoped_title_and_surface
test_orca_and_unsafe_metadata_remain_quarantined_by_refusal
test_external_project_recovery_needs_exact_replay_safe_authorization
test_secondmate_force_retirement_preflights_child_bindings
test_unusable_metadata_digest_refuses_before_authorizing
test_secondmate_preflight_refuses_unvalidated_nested_home

echo "# all endpoint binding migration tests passed"
