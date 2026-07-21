#!/usr/bin/env bash
# Behavior tests for bin/fm-project-mode.sh delivery-mode resolution.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-project-mode)
MODE="$ROOT/bin/fm-project-mode.sh"

test_standard_default_is_direct_pr() {
  local home out err
  home="$TMP_ROOT/default"
  mkdir -p "$home/data"
  err="$home/error"

  out=$(FM_HOME="$home" "$MODE" unregistered 2>"$err") \
    || fail "missing registry mode resolution failed"
  [ "$out" = "direct-PR off" ] || fail "missing registry did not resolve direct-PR off"
  assert_grep "defaulting unregistered to direct-PR off" "$err" \
    "missing registry warning did not name the direct-PR default"

  printf '%s\n' '- known - legacy unannotated entry (added 2026-07-21)' > "$home/data/projects.md"
  out=$(FM_HOME="$home" "$MODE" known 2>"$err") \
    || fail "unannotated project mode resolution failed"
  [ "$out" = "direct-PR off" ] || fail "unannotated project did not resolve direct-PR off"
  out=$(FM_HOME="$home" "$MODE" absent 2>"$err") \
    || fail "unregistered project mode resolution failed"
  [ "$out" = "direct-PR off" ] || fail "unregistered project did not resolve direct-PR off"
  pass "fm-project-mode.sh: missing, unregistered, and unannotated projects default to direct-PR"
}

test_explicit_modes_and_yolo_are_preserved() {
  local home out
  home="$TMP_ROOT/explicit"
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- gated [no-mistakes +yolo] - gated fixture (added 2026-07-21)
- direct [direct-PR] - direct fixture (added 2026-07-21)
- local [local-only +yolo] - local fixture (added 2026-07-21)
EOF

  out=$(FM_HOME="$home" "$MODE" gated) || fail "explicit no-mistakes resolution failed"
  [ "$out" = "no-mistakes on" ] || fail "explicit no-mistakes +yolo was not preserved"
  out=$(FM_HOME="$home" "$MODE" direct) || fail "explicit direct-PR resolution failed"
  [ "$out" = "direct-PR off" ] || fail "explicit direct-PR was not preserved"
  out=$(FM_HOME="$home" "$MODE" local) || fail "explicit local-only resolution failed"
  [ "$out" = "local-only on" ] || fail "explicit local-only +yolo was not preserved"
  pass "fm-project-mode.sh: explicit delivery modes and yolo remain authoritative"
}

test_task_override_wins_without_changing_yolo() {
  local home out
  home="$TMP_ROOT/task-override"
  mkdir -p "$home/data/task-a"
  printf '%s\n' '- app [direct-PR +yolo] - fixture (added 2026-07-21)' > "$home/data/projects.md"
  printf '%s\n' no-mistakes > "$home/data/task-a/delivery-mode"

  out=$(FM_HOME="$home" "$MODE" app --task task-a) || fail "task override resolution failed"
  [ "$out" = "no-mistakes on" ] || fail "task override did not win while preserving project yolo"
  [ "$(FM_HOME="$home" "$MODE" app)" = "direct-PR on" ] \
    || fail "task override leaked into project mode resolution"
  pass "fm-project-mode.sh: explicit task override wins and leaves yolo orthogonal"
}

test_malformed_explicit_modes_fail_closed() {
  local home out rc
  home="$TMP_ROOT/malformed"
  mkdir -p "$home/data/task-b"
  printf '%s\n' '- app [mystery] - fixture (added 2026-07-21)' > "$home/data/projects.md"
  rc=0
  out=$(FM_HOME="$home" "$MODE" app 2>&1) || rc=$?
  expect_code 2 "$rc" "unknown explicit project mode must fail closed"
  assert_contains "$out" 'unknown explicit mode "mystery"' \
    "unknown explicit project mode did not explain the refusal"

  printf '%s\n' '- app [direct-PR] - fixture (added 2026-07-21)' > "$home/data/projects.md"
  printf '%s\n' mystery > "$home/data/task-b/delivery-mode"
  rc=0
  out=$(FM_HOME="$home" "$MODE" app --task task-b 2>&1) || rc=$?
  expect_code 2 "$rc" "unknown explicit task mode must fail closed"
  assert_contains "$out" "unknown task delivery mode 'mystery'" \
    "unknown explicit task mode did not explain the refusal"
  pass "fm-project-mode.sh: malformed explicit modes fail closed"
}

test_standard_default_is_direct_pr
test_explicit_modes_and_yolo_are_preserved
test_task_override_wins_without_changing_yolo
test_malformed_explicit_modes_fail_closed

echo "# all fm-project-mode tests passed"
