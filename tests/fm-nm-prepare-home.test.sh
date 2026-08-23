#!/usr/bin/env bash
# Behavioral contract for fm_nm_prepare_home format-safe convergence, root
# boundary, owner-only permissions, and the per-task meta binding helper.
# Pairs with tests/fm-nm-home-isolation.test.sh (the core propagation contract).
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

nm_prep_tmproot() {
  fm_test_tmproot nm-prepare-home
}

# --- finding 3: format-safe agent: convergence -------------------------------
# The reader (bin/fm-spawn.sh no_mistakes_configured_reviewers) accepts inline,
# multiline-sequence, commented, and duplicate-key forms. The home preparer must
# handle every one without corrupting the file, and refuse a malformed config.

test_nm_prepare_home_converges_every_reader_syntax() {
  local TMP_ROOT HOME_A cfg count
  TMP_ROOT=$(nm_prep_tmproot)
  HOME_A="$TMP_ROOT/reader-syntax"
  mkdir -p "$HOME_A/.no-mistakes"
  cfg="$HOME_A/.no-mistakes/config.yaml"

  cat > "$cfg" <<'EOF'
agent: codex
session_reuse: true
EOF
  FM_HOME="$HOME_A" NM_HOME='' bash -c '. "$1"; fm_nm_prepare_home' _ "$ROOT/bin/fm-nm-run-lib.sh"
  grep -Fx 'agent: [codex]' "$cfg" >/dev/null || fail "scalar agent did not converge to agent: [codex]"
  grep -Fx 'session_reuse: true' "$cfg" >/dev/null || fail "scalar convergence discarded unrelated configuration"

  # Multiline sequence: the ad-hoc rewriter left the indented entries dangling
  # beneath a scalar. The whole sequence must be consumed and replaced.
  cat > "$cfg" <<'EOF'
agent:
  - claude
  - codex
session_reuse: true
EOF
  FM_HOME="$HOME_A" NM_HOME='' bash -c '. "$1"; fm_nm_prepare_home' _ "$ROOT/bin/fm-nm-run-lib.sh"
  grep -Fx 'agent: [codex]' "$cfg" >/dev/null || fail "multiline agent sequence did not converge to agent: [codex]"
  ! grep -E '^[[:space:]]+- ' "$cfg" >/dev/null || fail "multiline sequence entries were left dangling beneath the scalar"
  grep -Fx 'session_reuse: true' "$cfg" >/dev/null || fail "multiline convergence discarded unrelated configuration"
  ! grep -F 'claude' "$cfg" >/dev/null || fail "multiline convergence left a stale agent entry"

  # Comments and a trailing inline form must survive intact around the rewrite.
  cat > "$cfg" <<'EOF'
# reviewer selection lives here
agent: [claude, codex]  # prefer claude
session_reuse: true
EOF
  FM_HOME="$HOME_A" NM_HOME='' bash -c '. "$1"; fm_nm_prepare_home' _ "$ROOT/bin/fm-nm-run-lib.sh"
  grep -Fx 'agent: [codex]' "$cfg" >/dev/null || fail "commented inline agent did not converge to agent: [codex]"
  grep -Fx '# reviewer selection lives here' "$cfg" >/dev/null || fail "convergence dropped a full-line comment"
  grep -Fx 'session_reuse: true' "$cfg" >/dev/null || fail "commented convergence discarded unrelated configuration"
  ! grep -F 'claude' "$cfg" >/dev/null || fail "commented convergence left a stale agent entry"

  # Duplicate agent keys collapse to a single agent: [codex].
  cat > "$cfg" <<'EOF'
agent: [claude]
agent: [codex, claude]
session_reuse: true
EOF
  FM_HOME="$HOME_A" NM_HOME='' bash -c '. "$1"; fm_nm_prepare_home' _ "$ROOT/bin/fm-nm-run-lib.sh"
  count=$(grep -cE '^[[:space:]]*agent:' "$cfg" || true)
  [ "$count" = 1 ] || fail "duplicate agent keys did not collapse to one agent: line (got $count)"
  grep -Fx 'agent: [codex]' "$cfg" >/dev/null || fail "duplicate-key convergence did not produce agent: [codex]"
  grep -Fx 'session_reuse: true' "$cfg" >/dev/null || fail "duplicate-key convergence discarded unrelated configuration"
  ! grep -F 'claude' "$cfg" >/dev/null || fail "duplicate-key convergence left a stale agent entry"

  # A malformed config (unterminated flow sequence) must be refused, not silently
  # rewritten into a plausible shape.
  cat > "$cfg" <<'EOF'
agent: [claude, codex
session_reuse: true
EOF
  if FM_HOME="$HOME_A" NM_HOME='' bash -c '. "$1"; fm_nm_prepare_home' _ "$ROOT/bin/fm-nm-run-lib.sh" 2>/dev/null; then
    fail "malformed agent config was accepted instead of refused"
  fi

  pass "fm_nm_prepare_home converges every reader-accepted agent syntax and refuses malformed config"
}

# --- finding 4: reject a symlinked or special-file private root ---------------
# The default root must remain a real directory contained by canonical FM_HOME;
# a symlinked or special-file $FM_HOME/.no-mistakes must be rejected before write.

test_nm_prepare_home_rejects_symlinked_and_special_roots() {
  local TMP_ROOT HOME_A outside real_root mode
  TMP_ROOT=$(nm_prep_tmproot)
  HOME_A="$TMP_ROOT/symlink-home"
  outside="$TMP_ROOT/outside"
  real_root="$TMP_ROOT/real-home"
  mkdir -p "$HOME_A" "$outside" "$real_root"

  # A symlinked $FM_HOME/.no-mistakes pointing outside the home must not be
  # followed; the preparer refuses rather than creating config outside FM_HOME.
  ln -s "$outside" "$HOME_A/.no-mistakes"
  if FM_HOME="$HOME_A" NM_HOME='' bash -c '. "$1"; fm_nm_prepare_home' _ "$ROOT/bin/fm-nm-run-lib.sh" 2>/dev/null; then
    fail "symlinked private root was followed outside FM_HOME instead of refused"
  fi
  [ ! -e "$outside/config.yaml" ] || fail "symlinked root escape created config outside FM_HOME"

  rm -f "$HOME_A/.no-mistakes"
  # A special file (regular file) at the root path must also be refused.
  : > "$HOME_A/.no-mistakes"
  if FM_HOME="$HOME_A" NM_HOME='' bash -c '. "$1"; fm_nm_prepare_home' _ "$ROOT/bin/fm-nm-run-lib.sh" 2>/dev/null; then
    fail "special-file private root was accepted instead of refused"
  fi

  # The canonical default root must remain inside canonical FM_HOME: a real
  # directory created by the preparer, never a symlink.
  FM_HOME="$real_root" NM_HOME='' bash -c '. "$1"; fm_nm_prepare_home' _ "$ROOT/bin/fm-nm-run-lib.sh"
  [ -d "$real_root/.no-mistakes" ] || fail "canonical default root was not created as a real directory"
  [ ! -L "$real_root/.no-mistakes" ] || fail "canonical default root is a symlink"
  [ "$(cd "$real_root/.no-mistakes" && pwd -P)" = "$(cd "$real_root" && pwd -P)/.no-mistakes" ] \
    || fail "canonical default root escaped its containing FM_HOME"

  pass "fm_nm_prepare_home rejects symlinked and special-file roots and keeps the default root inside canonical FM_HOME"
}

# --- finding 5: owner-only permissions and unsafe-type/mode convergence ------
# The captain-private root and config are created owner-only and published via
# a safe temporary file; unsafe existing types/modes are validated or converged.

test_nm_prepare_home_creates_owner_only_and_converges_unsafe() {
  local TMP_ROOT HOME_A root cfg mode override outside
  TMP_ROOT=$(nm_prep_tmproot)
  HOME_A="$TMP_ROOT/mode-home"
  mkdir -p "$HOME_A"
  root="$HOME_A/.no-mistakes"
  cfg="$root/config.yaml"

  # Under a permissive umask, the root and config must still be owner-only.
  ( umask 022
    FM_HOME="$HOME_A" NM_HOME='' bash -c '. "$1"; fm_nm_prepare_home' _ "$ROOT/bin/fm-nm-run-lib.sh" )
  [ -d "$root" ] || fail "owner-only root was not created"
  [ -f "$cfg" ] || fail "owner-only config was not created"
  mode=$(stat -c %a "$root" 2>/dev/null || stat -f %Lp "$root")
  [ "$mode" = 700 ] || fail "private root is world-readable (mode $mode, expected 700)"
  mode=$(stat -c %a "$cfg" 2>/dev/null || stat -f %Lp "$cfg")
  [ "$mode" = 600 ] || fail "private config is world-readable (mode $mode, expected 600)"

  rm -f "$cfg"
  outside="$TMP_ROOT/outside-config"
  printf 'untouched\n' > "$outside"
  FM_HOME="$HOME_A" NM_HOME='' bash -c '
    . "$1"
    ln -s "$2" "$3/config.yaml.tmp.$$"
    fm_nm_prepare_home
  ' _ "$ROOT/bin/fm-nm-run-lib.sh" "$outside" "$root"
  [ "$(cat "$outside")" = untouched ] || fail "predictable temporary symlink overwrote an outside file"
  [ -f "$cfg" ] && [ ! -L "$cfg" ] || fail "initial config was not safely published as a regular file"

  # An existing world-readable root and config are converged to owner-only.
  chmod 0755 "$root" 2>/dev/null || true
  chmod 0644 "$cfg" 2>/dev/null || true
  FM_HOME="$HOME_A" NM_HOME='' bash -c '. "$1"; fm_nm_prepare_home' _ "$ROOT/bin/fm-nm-run-lib.sh"
  mode=$(stat -c %a "$root" 2>/dev/null || stat -f %Lp "$root")
  [ "$mode" = 700 ] || fail "existing world-readable root was not converged to 700 (got $mode)"
  mode=$(stat -c %a "$cfg" 2>/dev/null || stat -f %Lp "$cfg")
  [ "$mode" = 600 ] || fail "existing world-readable config was not converged to 600 (got $mode)"

  # An explicit operator NM_HOME override is left untouched by the preparer
  # (the preparer only owns the home-private default root).
  override="$TMP_ROOT/operator-nm"
  mkdir -p "$override"
  FM_HOME="$HOME_A" NM_HOME="$override" bash -c '. "$1"; fm_nm_prepare_home' _ "$ROOT/bin/fm-nm-run-lib.sh"
  [ ! -e "$override/config.yaml" ] \
    || fail "preparer wrote config into an explicit operator NM_HOME override it does not own"

  pass "fm_nm_prepare_home creates owner-only root/config and converges unsafe existing permissions"
}

# --- finding 2: per-task meta binding helper ---------------------------------
# fm_nm_home_for_meta returns the meta-bound root when present, and the legacy
# shared default root when absent, so pre-rollout parked runs never disappear.

test_nm_home_for_meta_binds_per_task_and_falls_back_to_legacy() {
  local TMP_ROOT meta legacy_root bound_root result
  TMP_ROOT=$(nm_prep_tmproot)
  meta="$TMP_ROOT/task.meta"
  legacy_root="$HOME/.no-mistakes"

  # A pre-rollout task (no nm_home in meta) is observed at the legacy shared root
  # so its parked run stays visible (no false negative).
  printf 'window=firstmate:fm-legacy\nworktree=%s/wt\nkind=ship\nmode=no-mistakes\n' "$TMP_ROOT" > "$meta"
  result=$(HOME="$HOME" bash -c '. "$1"; . "$2"; fm_nm_home_for_meta "$3"' _ "$ROOT/bin/fm-backend.sh" "$ROOT/bin/fm-nm-run-lib.sh" "$meta")
  [ "$result" = "$legacy_root" ] \
    || fail "legacy task without nm_home did not fall back to the shared default root (got $result)"

  # A post-rollout task is observed at its exact bound root, not the legacy root.
  bound_root="$TMP_ROOT/private-nm"
  printf 'window=firstmate:fm-task\nworktree=%s/wt\nkind=ship\nmode=no-mistakes\nnm_home=%s\n' "$TMP_ROOT" "$bound_root" > "$meta"
  result=$(HOME="$HOME" bash -c '. "$1"; . "$2"; fm_nm_home_for_meta "$3"' _ "$ROOT/bin/fm-backend.sh" "$ROOT/bin/fm-nm-run-lib.sh" "$meta")
  [ "$result" = "$bound_root" ] \
    || fail "post-rollout task was not observed at its bound nm_home (got $result)"

  # A missing meta file falls back to the legacy root rather than failing open
  # into the new private root.
  result=$(HOME="$HOME" bash -c '. "$1"; . "$2"; fm_nm_home_for_meta "$3"' _ "$ROOT/bin/fm-backend.sh" "$ROOT/bin/fm-nm-run-lib.sh" "$TMP_ROOT/missing.meta")
  [ "$result" = "$legacy_root" ] \
    || fail "missing meta did not fall back to the legacy shared root (got $result)"

  printf 'nm_home=%s\nnm_home=%s\n' "$bound_root" "$TMP_ROOT/foreign-nm" > "$meta"
  if HOME="$HOME" bash -c '. "$1"; . "$2"; fm_nm_home_for_meta "$3"' _ \
    "$ROOT/bin/fm-backend.sh" "$ROOT/bin/fm-nm-run-lib.sh" "$meta" >/dev/null 2>&1; then
    fail "duplicate nm_home bindings were accepted"
  fi

  printf 'nm_home=\n' > "$meta"
  if HOME="$HOME" bash -c '. "$1"; . "$2"; fm_nm_home_for_meta "$3"' _ \
    "$ROOT/bin/fm-backend.sh" "$ROOT/bin/fm-nm-run-lib.sh" "$meta" >/dev/null 2>&1; then
    fail "empty nm_home binding was treated as a legacy task"
  fi

  pass "fm_nm_home_for_meta binds the run root per task and falls back to the legacy shared root"
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  test_nm_prepare_home_converges_every_reader_syntax
  test_nm_prepare_home_rejects_symlinked_and_special_roots
  test_nm_prepare_home_creates_owner_only_and_converges_unsafe
  test_nm_home_for_meta_binds_per_task_and_falls_back_to_legacy
  echo "# all fm-nm-prepare-home tests passed"
fi
