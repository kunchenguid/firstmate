#!/usr/bin/env bash
# Behavior tests for bin/fm-project-mode.sh registry parsing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-project-mode)

test_mode_yolo_and_base_parse_independently() {
  local home out base
  home="$TMP_ROOT/home"
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- arena-crm [no-mistakes base=origin/dev] - Arena CRM (added 2026-07-06)
- yolo-app [direct-PR +yolo base=origin/release] - yolo app (added 2026-07-06)
EOF

  out=$(FM_HOME="$home" "$ROOT/bin/fm-project-mode.sh" arena-crm)
  [ "$out" = "no-mistakes off" ] || fail "mode/yolo parse changed for base-bearing line: $out"
  base=$(FM_HOME="$home" "$ROOT/bin/fm-project-mode.sh" --base arena-crm)
  [ "$base" = "origin/dev" ] || fail "base parse failed for arena-crm: $base"

  out=$(FM_HOME="$home" "$ROOT/bin/fm-project-mode.sh" yolo-app)
  [ "$out" = "direct-PR on" ] || fail "mode/yolo parse failed with +yolo and base: $out"
  base=$(FM_HOME="$home" "$ROOT/bin/fm-project-mode.sh" --base yolo-app)
  [ "$base" = "origin/release" ] || fail "base parse failed with +yolo: $base"

  base=$(FM_HOME="$home" "$ROOT/bin/fm-project-mode.sh" --base missing-project 2>/dev/null)
  [ -z "$base" ] || fail "missing project should have empty base, got: $base"
  pass "fm-project-mode.sh: base=... parses without changing mode/yolo output"
}

test_mode_yolo_and_base_parse_independently
