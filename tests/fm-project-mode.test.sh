#!/usr/bin/env bash
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MODE="$ROOT/bin/fm-project-mode.sh"
TMP_ROOT=$(fm_test_tmproot fm-project-mode)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data"

cat > "$HOME_DIR/data/projects.md" <<'EOF'
- guarded [no-mistakes] - explicit guarded project (added 2026-07-30)
- ordinary [direct-PR] - explicit ordinary project (added 2026-07-30)
- local [local-only +yolo] - local project (added 2026-07-30)
- legacy - unannotated project (added 2026-07-30)
EOF

[ "$(FM_HOME="$HOME_DIR" "$MODE" guarded)" = "no-mistakes off" ] || fail "explicit no-mistakes changed"
[ "$(FM_HOME="$HOME_DIR" "$MODE" ordinary)" = "direct-PR off" ] || fail "explicit direct-PR changed"
[ "$(FM_HOME="$HOME_DIR" "$MODE" local)" = "local-only on" ] || fail "local-only +yolo changed"
[ "$(FM_HOME="$HOME_DIR" "$MODE" legacy)" = "direct-PR off" ] || fail "unannotated project did not default to direct-PR"
[ "$(FM_HOME="$HOME_DIR" "$MODE" missing 2>/dev/null)" = "direct-PR off" ] || fail "missing project did not default to direct-PR"

rm "$HOME_DIR/data/projects.md"
[ "$(FM_HOME="$HOME_DIR" "$MODE" missing 2>/dev/null)" = "direct-PR off" ] || fail "missing registry did not default to direct-PR"
pass "project delivery modes retain explicit values and default ordinary work to direct-PR"
