#!/usr/bin/env bash
# Parser default tests for bin/fm-project-mode.sh.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PM="$ROOT/bin/fm-project-mode.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/data"

fail() { echo "not ok - $1"; exit 1; }
pass() { echo "ok - $1"; }

# --- missing registry defaults to direct-PR off ---
out=$(FM_HOME="$HOME_DIR" "$PM" unknown-project 2>/dev/null)
[ "$out" = "direct-PR off" ] || fail "missing registry default: $out"
pass "missing registry defaults to direct-PR off"

# --- unknown project defaults to direct-PR off ---
cat > "$HOME_DIR/data/projects.md" <<'EOF'
- firstmate - Firstmate/OMX delivery control plane (added 2026-07-22)
- covenant [direct-PR +yolo] - shop platform (added 2026-07-22)
- dotfiles [local-only] - machine config (added 2026-07-22)
- muse [no-mistakes] - content orchestration (added 2026-07-22)
EOF
out=$(FM_HOME="$HOME_DIR" "$PM" unknown-project 2>/dev/null)
[ "$out" = "direct-PR off" ] || fail "unknown project default: $out"
pass "unknown project defaults to direct-PR off"

out=$(FM_HOME="$HOME_DIR" "$PM" firstmate 2>/dev/null)
[ "$out" = "direct-PR on" ] || fail "legacy registry migration: $out"
pass "legacy registry entries migrate to direct-PR on"

# --- explicit modes preserved ---
out=$(FM_HOME="$HOME_DIR" "$PM" covenant 2>/dev/null)
[ "$out" = "direct-PR on" ] || fail "explicit direct-PR+yolo: $out"
out=$(FM_HOME="$HOME_DIR" "$PM" dotfiles 2>/dev/null)
[ "$out" = "local-only off" ] || fail "explicit local-only: $out"
out=$(FM_HOME="$HOME_DIR" "$PM" muse 2>/dev/null)
[ "$out" = "no-mistakes off" ] || fail "explicit no-mistakes: $out"
pass "explicit modes and yolo flags are preserved"

# --- malformed mode defaults to direct-PR off ---
cat > "$HOME_DIR/data/projects.md" <<'EOF'
- badproj [garbage +yolo] - bad entry (added 2026-07-22)
EOF
out=$(FM_HOME="$HOME_DIR" "$PM" badproj 2>/dev/null)
[ "$out" = "direct-PR off" ] || fail "malformed mode default: $out"
pass "malformed mode defaults to direct-PR off"

cat > "$HOME_DIR/data/projects.md" <<'EOF'
- badproj [+yolo] - missing mode (added 2026-07-22)
EOF
out=$(FM_HOME="$HOME_DIR" "$PM" badproj 2>/dev/null)
[ "$out" = "direct-PR off" ] || fail "missing mode granted authority: $out"
pass "mode-less yolo entry fails closed"

pass "all fm-project-mode tests passed"
