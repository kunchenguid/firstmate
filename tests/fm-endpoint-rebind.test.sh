#!/usr/bin/env bash
# Regression tests for verified legacy Herdr endpoint re-binding.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

file_mode() {  # <path>
  local mode
  mode=$(stat -f %Lp "$1" 2>/dev/null) || mode=
  case "$mode" in
    ''|*[!0-7]*) mode=$(stat -c %a "$1" 2>/dev/null) || mode= ;;
  esac
  case "$mode" in
    ''|*[!0-7]*) return 1 ;;
  esac
  printf '%s\n' "$mode"
}

# Install a single-flavor stat (and a contradicting uname) so the repair's mode
# read is exercised against a host whose stat syntax the OS name would mispick.
install_stat_flavor() {  # <case> <bsd|gnu|broken>
  local dir=$1 flavor=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  case "$flavor" in
    bsd)
      cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
printf 'Linux\n'
SH
      cat > "$fakebin/stat" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_STAT_LOG:?}"
case "$1 $2" in
  '-f %Lp') printf '644\n' ;;
  -c\ *) printf 'stat: illegal option -- c\n' >&2; exit 1 ;;
  *) exit 2 ;;
esac
SH
      ;;
    gnu)
      cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
printf 'Darwin\n'
SH
      cat > "$fakebin/stat" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_STAT_LOG:?}"
case "$1 $2" in
  '-c %a') printf '644\n' ;;
  -f\ *)
    printf '  File: "%s"\nBlocks: Total: 1\n' "$2"
    exit 1
    ;;
  *) exit 2 ;;
esac
SH
      ;;
    broken)
      cat > "$fakebin/stat" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_STAT_LOG:?}"
printf 'stat: cannot read file mode\n' >&2
exit 1
SH
      ;;
    *) fail "unknown stat flavor $flavor" ;;
  esac
  chmod +x "$fakebin/stat"
  [ ! -e "$fakebin/uname" ] || chmod +x "$fakebin/uname"
}

REBIND="$ROOT/bin/fm-endpoint-rebind.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-endpoint-rebind)

make_case() {  # <name>
  local dir="$TMP_ROOT/$1" fakebin
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/worktree" "$dir/project"
  fakebin=$(fm_fakebin "$dir")
  : > "$dir/herdr.log"
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
printf '<%s>' "$@" >> "${FM_HERDR_LOG:?}"
printf '\n' >> "${FM_HERDR_LOG:?}"
cmd=${1:-}
sub=${2:-}
case "$cmd $sub" in
  'pane get')
    if [ -n "${FM_FAKE_MUTATE_META:-}" ] && [ ! -e "${FM_FAKE_MUTATE_MARKER:?}" ]; then
      : > "$FM_FAKE_MUTATE_MARKER"
      printf 'note=changed-during-proof\n' >> "$FM_FAKE_MUTATE_META"
    fi
    cwd=${FM_FAKE_CWD:?}
    if [ -n "${FM_FAKE_DRIFT_CWD:-}" ]; then
      if [ -e "${FM_FAKE_DRIFT_MARKER:?}" ]; then
        cwd=$FM_FAKE_DRIFT_CWD
      else
        : > "$FM_FAKE_DRIFT_MARKER"
      fi
    fi
    printf '{"result":{"pane":{"pane_id":"%s","tab_id":"%s","workspace_id":"%s","foreground_cwd":"%s"}}}\n' \
      "${FM_FAKE_PANE:-w1:p2}" "${FM_FAKE_PANE_TAB:-w1:t2}" \
      "${FM_FAKE_PANE_WORKSPACE:-w1}" "$cwd"
    ;;
  'tab get')
    printf '{"result":{"tab":{"tab_id":"%s","workspace_id":"%s","label":"%s"}}}\n' \
      "${FM_FAKE_TAB:-w1:t2}" "${FM_FAKE_TAB_WORKSPACE:-w1}" \
      "${FM_FAKE_LABEL:-fm-legacy-task}"
    ;;
  'workspace list')
    printf '{"result":{"workspaces":[{"workspace_id":"%s"}]}}\n' \
      "${FM_FAKE_WORKSPACE:-w1}"
    ;;
  'tab list')
    if [ "${FM_FAKE_DUPLICATE_LABEL:-0}" = 1 ]; then
      printf '{"result":{"tabs":[{"tab_id":"w1:t2","label":"fm-legacy-task"},{"tab_id":"w1:t9","label":"fm-legacy-task"}]}}\n'
    else
      printf '{"result":{"tabs":[{"tab_id":"%s","label":"%s"}]}}\n' \
        "${FM_FAKE_TAB:-w1:t2}" "${FM_FAKE_LABEL:-fm-legacy-task}"
    fi
    ;;
  'pane list')
    printf '{"result":{"panes":[{"pane_id":"%s","tab_id":"%s"}]}}\n' \
      "${FM_FAKE_PANE:-w1:p2}" "${FM_FAKE_PANE_TAB:-w1:t2}"
    ;;
  *) exit 91 ;;
esac
SH
  chmod +x "$fakebin/herdr"
  printf '%s\n' "$dir"
}

seed_legacy_meta() {  # <case> [id]
  local dir=$1 id=${2:-legacy-task}
  fm_write_meta "$dir/home/state/$id.meta" \
    'window=lab:w1:p2' \
    "worktree=$dir/worktree" \
    "project=$dir/project" \
    'harness=claude' \
    'kind=ship' \
    'backend=herdr' \
    'herdr_session=lab' \
    'herdr_workspace_id=w1' \
    'herdr_tab_id=w1:t2' \
    'herdr_pane_id=w1:p2'
}

run_rebind() {  # <case> [id]
  local dir=$1 id=${2:-legacy-task}
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_HERDR_LOG="$dir/herdr.log" FM_FAKE_CWD="${FM_FAKE_CWD:-$dir/worktree}" \
    FM_FAKE_LABEL="${FM_FAKE_LABEL:-fm-$id}" PATH="$dir/fakebin:$PATH" \
    "$REBIND" "$id"
}

assert_rebind_refused_unchanged() {  # <case> <description> <expected-refusal>
  local dir=$1 description=$2 expected=$3 before rc
  before="$dir/before.meta"
  cp "$dir/home/state/legacy-task.meta" "$before"
  set +e
  run_rebind "$dir" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "$description: re-binding unexpectedly succeeded"
  assert_grep "$expected" "$dir/stderr" \
    "$description: refusal did not report the expected reason"
  cmp -s "$before" "$dir/home/state/legacy-task.meta" \
    || fail "$description: refused repair changed metadata"
  assert_no_grep 'endpoint_task_id=' "$dir/home/state/legacy-task.meta" \
    "$description: refused repair published a binding"
}

test_verified_live_identity_is_published() {
  local dir output rc legacy
  dir=$(make_case success)
  seed_legacy_meta "$dir"
  legacy=$(cat "$dir/home/state/legacy-task.meta")
  printf '%s' "$legacy" > "$dir/home/state/legacy-task.meta"
  chmod 0644 "$dir/home/state/legacy-task.meta"
  set +e
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_HERDR_LOG="$dir/herdr.log" \
    PATH="$dir/fakebin:$PATH" "$TEARDOWN" legacy-task --force \
    > "$dir/teardown.out" 2> "$dir/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "legacy Herdr metadata unexpectedly bypassed teardown's binding guard"
  assert_grep 'lacks an exact task binding' "$dir/teardown.err" \
    "legacy Herdr metadata did not reproduce the cleanup refusal"
  assert_grep 'fm-endpoint-rebind.sh legacy-task' "$dir/teardown.err" \
    "cleanup refusal did not identify the supported repair path"
  [ ! -s "$dir/herdr.log" ] || fail "legacy cleanup refusal reached Herdr before repair"

  output=$(run_rebind "$dir") || fail "verified legacy Herdr endpoint did not re-bind"
  assert_contains "$output" 'verified endpoint binding recorded for task legacy-task' \
    "successful repair did not report its result"
  [ "$(grep -c '^endpoint_task_id=' "$dir/home/state/legacy-task.meta")" -eq 1 ] \
    || fail "successful repair did not publish exactly one endpoint binding"
  assert_grep 'endpoint_task_id=legacy-task' "$dir/home/state/legacy-task.meta" \
    "successful repair published the wrong task binding"
  FM_ROOT_OVERRIDE="$ROOT" bash -c \
    '. "$1/bin/fm-backend.sh"; fm_backend_validate_task_endpoint "$2" legacy-task' \
    _ "$ROOT" "$dir/home/state/legacy-task.meta" \
    || fail "published metadata does not pass the unchanged teardown validator"
  [ "$(wc -l < "$dir/herdr.log" | tr -d '[:space:]')" -eq 7 ] \
    || fail "successful repair did not perform the bounded live proof"
  [ "$(file_mode "$dir/home/state/legacy-task.meta")" = 644 ] \
    || fail "successful repair did not preserve the metadata file mode"
  pass "endpoint re-binding: exact live Herdr identity and worktree proof publishes one teardown-valid binding"
}

test_existing_valid_binding_is_idempotent() {
  local dir output
  dir=$(make_case already-bound)
  seed_legacy_meta "$dir"
  printf 'endpoint_task_id=legacy-task\n' >> "$dir/home/state/legacy-task.meta"
  output=$(run_rebind "$dir") || fail "existing valid binding was not accepted idempotently"
  assert_contains "$output" 'already valid' "idempotent repair did not report the existing binding"
  [ ! -s "$dir/herdr.log" ] || fail "idempotent repair queried Herdr unnecessarily"
  pass "endpoint re-binding: an existing exact binding is a validated read-only no-op"
}

test_wrong_live_evidence_refuses_without_mutation() {
  local dir
  dir=$(make_case wrong-label)
  seed_legacy_meta "$dir"
  FM_FAKE_LABEL=fm-other-task assert_rebind_refused_unchanged "$dir" "wrong task label" \
    'live Herdr pane, task label, or worktree does not exactly match task legacy-task'

  dir=$(make_case wrong-cwd)
  seed_legacy_meta "$dir"
  mkdir -p "$dir/other-worktree"
  FM_FAKE_CWD="$dir/other-worktree" assert_rebind_refused_unchanged "$dir" "wrong live worktree" \
    'live Herdr pane, task label, or worktree does not exactly match task legacy-task'

  dir=$(make_case wrong-relation)
  seed_legacy_meta "$dir"
  FM_FAKE_PANE_TAB=w1:t9 assert_rebind_refused_unchanged "$dir" "wrong pane-to-tab relationship" \
    'live Herdr pane, task label, or worktree does not exactly match task legacy-task'

  dir=$(make_case duplicate-label)
  seed_legacy_meta "$dir"
  FM_FAKE_DUPLICATE_LABEL=1 assert_rebind_refused_unchanged "$dir" "duplicate task label" \
    'Herdr task tab for task legacy-task is absent, duplicated, or relabeled'
  pass "endpoint re-binding: relabeled, moved, contradictory, and duplicate live Herdr evidence is preserved and refused"
}

test_competing_metadata_claim_refuses_before_runtime_read() {
  local dir
  dir=$(make_case competing)
  seed_legacy_meta "$dir"
  fm_write_meta "$dir/home/state/other-task.meta" \
    'window=lab:w1:p2' "worktree=$dir/other" "project=$dir/project" \
    'backend=herdr' 'herdr_session=lab' 'herdr_workspace_id=w1' \
    'herdr_tab_id=w1:t2' 'herdr_pane_id=w1:p2'
  assert_rebind_refused_unchanged "$dir" "competing task metadata" \
    'task other-task also claims the recorded Herdr endpoint for task legacy-task'
  [ ! -s "$dir/herdr.log" ] || fail "competing metadata claim reached the runtime"

  dir=$(make_case competing-worktree-alias)
  seed_legacy_meta "$dir"
  ln -s "$dir/worktree" "$dir/worktree-alias"
  fm_write_meta "$dir/home/state/other-task.meta" \
    'window=lab:w9:p9' "worktree=$dir/worktree-alias" "project=$dir/project" \
    'backend=herdr' 'herdr_session=lab' 'herdr_workspace_id=w9' \
    'herdr_tab_id=w9:t9' 'herdr_pane_id=w9:p9'
  assert_rebind_refused_unchanged "$dir" "competing canonical worktree metadata" \
    'task other-task also claims the recorded worktree for task legacy-task'
  [ ! -s "$dir/herdr.log" ] || fail "canonical worktree collision reached the runtime"
  pass "endpoint re-binding: another task's endpoint or canonical worktree claim refuses before any Herdr read"
}

test_invalid_legacy_metadata_refuses_before_runtime_read() {
  local dir rc
  dir=$(make_case malformed)
  seed_legacy_meta "$dir"
  printf 'endpoint_task_id=\n' >> "$dir/home/state/legacy-task.meta"
  set +e
  run_rebind "$dir" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "empty existing binding unexpectedly repaired"
  assert_grep 'task legacy-task has an empty endpoint task binding' "$dir/stderr" \
    "empty existing binding did not report the expected reason"
  [ ! -s "$dir/herdr.log" ] || fail "empty existing binding reached the runtime"

  dir=$(make_case malformed-shape)
  seed_legacy_meta "$dir"
  awk '{ sub(/^window=.*/, "window=lab:w1:p9"); print }' \
    "$dir/home/state/legacy-task.meta" > "$dir/new"
  mv "$dir/new" "$dir/home/state/legacy-task.meta"
  assert_rebind_refused_unchanged "$dir" "inconsistent Herdr metadata" \
    'Herdr endpoint metadata for task legacy-task is malformed or inconsistent'
  [ ! -s "$dir/herdr.log" ] || fail "inconsistent Herdr metadata reached the runtime"

  dir=$(make_case non-herdr)
  seed_legacy_meta "$dir"
  awk '$0 != "backend=herdr"' "$dir/home/state/legacy-task.meta" > "$dir/new"
  mv "$dir/new" "$dir/home/state/legacy-task.meta"
  assert_rebind_refused_unchanged "$dir" "non-Herdr metadata" \
    'verified legacy endpoint re-binding currently supports Herdr metadata only'
  [ ! -s "$dir/herdr.log" ] || fail "non-Herdr metadata reached the runtime"
  pass "endpoint re-binding: malformed bindings, inconsistent shapes, and non-Herdr records refuse before runtime access"
}

test_metadata_change_during_proof_is_not_overwritten() {
  local dir rc
  dir=$(make_case changed-source)
  seed_legacy_meta "$dir"
  set +e
  FM_FAKE_MUTATE_META="$dir/home/state/legacy-task.meta" \
    FM_FAKE_MUTATE_MARKER="$dir/mutated" run_rebind "$dir" \
    > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "metadata changed during proof was overwritten"
  assert_grep 'note=changed-during-proof' "$dir/home/state/legacy-task.meta" \
    "concurrent metadata change was not preserved"
  assert_no_grep 'endpoint_task_id=' "$dir/home/state/legacy-task.meta" \
    "metadata changed during proof gained a binding"
  pass "endpoint re-binding: source-byte changes during live proof refuse instead of overwriting newer metadata"
}

test_live_endpoint_change_between_snapshots_refuses() {
  local dir
  dir=$(make_case drifted-endpoint)
  seed_legacy_meta "$dir"
  mkdir -p "$dir/other-worktree"
  FM_FAKE_DRIFT_CWD="$dir/other-worktree" FM_FAKE_DRIFT_MARKER="$dir/drifted" \
    assert_rebind_refused_unchanged "$dir" "live endpoint changed between snapshots" \
    'live Herdr endpoint for task legacy-task changed during ownership verification'
  [ -e "$dir/drifted" ] || fail "live endpoint drift case never reached the first live snapshot"
  pass "endpoint re-binding: live endpoint state that changes between snapshots is ambiguity, not repair authority"
}

test_metadata_mode_survives_either_stat_flavor() {
  local dir output flavor
  for flavor in bsd gnu; do
    dir=$(make_case "stat-$flavor")
    seed_legacy_meta "$dir"
    install_stat_flavor "$dir" "$flavor"
    chmod 0644 "$dir/home/state/legacy-task.meta"
    output=$(FM_STAT_LOG="$dir/stat.log" run_rebind "$dir") \
      || fail "$flavor stat flavor blocked an otherwise verified repair"
    assert_contains "$output" 'verified endpoint binding recorded for task legacy-task' \
      "$flavor stat flavor did not publish the verified binding"
    [ "$(file_mode "$dir/home/state/legacy-task.meta")" = 644 ] \
      || fail "$flavor stat flavor did not preserve the metadata file mode"
  done
  assert_grep '-f %Lp' "$TMP_ROOT/stat-bsd/stat.log" \
    "BSD-only stat host never received a BSD-syntax mode read"
  assert_no_grep '-c ' "$TMP_ROOT/stat-bsd/stat.log" \
    "BSD-only stat host was asked for a GNU-syntax mode"
  assert_grep '-c %a' "$TMP_ROOT/stat-gnu/stat.log" \
    "GNU-only stat host never received a GNU-syntax mode read"

  dir=$(make_case stat-unreadable)
  seed_legacy_meta "$dir"
  install_stat_flavor "$dir" broken
  FM_STAT_LOG="$dir/stat.log" assert_rebind_refused_unchanged "$dir" "unreadable metadata file mode" \
    'file mode of endpoint metadata for task legacy-task could not be read'
  pass "endpoint re-binding: the published mode follows the installed stat flavor, not the OS name, and an unreadable mode refuses"
}

test_verified_live_identity_is_published
test_existing_valid_binding_is_idempotent
test_metadata_mode_survives_either_stat_flavor
test_live_endpoint_change_between_snapshots_refuses
test_wrong_live_evidence_refuses_without_mutation
test_competing_metadata_claim_refuses_before_runtime_read
test_invalid_legacy_metadata_refuses_before_runtime_read
test_metadata_change_during_proof_is_not_overwritten
