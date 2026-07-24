#!/usr/bin/env bash
# Behavior tests for bin/fm-project-mode.sh delivery-mode defaults and parsing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-project-mode)
MODE_BIN="$ROOT/bin/fm-project-mode.sh"

write_registry() {
  local home=$1
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- bare-legacy - fixture without mode brackets (added 2026-07-01)
- preview-explicit [fast-preview] - explicit fast-preview (added 2026-07-01)
- nm-explicit [no-mistakes] - explicit no-mistakes (added 2026-07-01)
- direct-explicit [direct-PR] - explicit direct-PR (added 2026-07-01)
- local-explicit [local-only] - explicit local-only (added 2026-07-01)
- yolo-preview [fast-preview +yolo] - fast-preview with yolo (added 2026-07-01)
- unknown-mode [not-a-mode] - unknown token (added 2026-07-01)
EOF
}

test_missing_registry_defaults_fast_preview() {
  local home out
  home="$TMP_ROOT/missing-reg"
  mkdir -p "$home/data"
  out=$(FM_HOME="$home" "$MODE_BIN" anyproj 2>/dev/null) || true
  [ "$out" = "fast-preview off" ] || fail "missing registry should default fast-preview off, got '$out'"
  pass "fm-project-mode: missing registry defaults to fast-preview off"
}

test_absent_project_defaults_fast_preview() {
  local home out
  home="$TMP_ROOT/absent-proj"
  write_registry "$home"
  out=$(FM_HOME="$home" "$MODE_BIN" not-listed 2>/dev/null) || true
  [ "$out" = "fast-preview off" ] || fail "absent project should default fast-preview off, got '$out'"
  pass "fm-project-mode: absent project defaults to fast-preview off"
}

test_legacy_bare_line_inherits_fast_preview() {
  local home out
  home="$TMP_ROOT/legacy"
  write_registry "$home"
  out=$(FM_HOME="$home" "$MODE_BIN" bare-legacy 2>/dev/null) || true
  [ "$out" = "fast-preview off" ] || fail "legacy bare line should inherit fast-preview, got '$out'"
  pass "fm-project-mode: bare legacy registry line inherits fast-preview"
}

test_explicit_modes_preserved() {
  local home out
  home="$TMP_ROOT/explicit"
  write_registry "$home"
  out=$(FM_HOME="$home" "$MODE_BIN" preview-explicit 2>/dev/null) || true
  [ "$out" = "fast-preview off" ] || fail "explicit fast-preview lost, got '$out'"
  out=$(FM_HOME="$home" "$MODE_BIN" nm-explicit 2>/dev/null) || true
  [ "$out" = "no-mistakes off" ] || fail "explicit no-mistakes lost, got '$out'"
  out=$(FM_HOME="$home" "$MODE_BIN" direct-explicit 2>/dev/null) || true
  [ "$out" = "direct-PR off" ] || fail "explicit direct-PR lost, got '$out'"
  out=$(FM_HOME="$home" "$MODE_BIN" local-explicit 2>/dev/null) || true
  [ "$out" = "local-only off" ] || fail "explicit local-only lost, got '$out'"
  out=$(FM_HOME="$home" "$MODE_BIN" yolo-preview 2>/dev/null) || true
  [ "$out" = "fast-preview on" ] || fail "fast-preview +yolo lost, got '$out'"
  pass "fm-project-mode: explicit modes and +yolo are preserved"
}

test_unknown_mode_defaults_fast_preview() {
  local home out
  home="$TMP_ROOT/unknown"
  write_registry "$home"
  out=$(FM_HOME="$home" "$MODE_BIN" unknown-mode 2>/dev/null) || true
  [ "$out" = "fast-preview off" ] || fail "unknown mode should default fast-preview off, got '$out'"
  pass "fm-project-mode: unknown mode token defaults to fast-preview off"
}

test_missing_registry_defaults_fast_preview
test_absent_project_defaults_fast_preview
test_legacy_bare_line_inherits_fast_preview
test_explicit_modes_preserved
test_unknown_mode_defaults_fast_preview
