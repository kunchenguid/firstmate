#!/usr/bin/env bash
# Behavior tests for bin/fm-claude-trust-lib.sh: the claude workspace-trust
# pre-accept step bin/fm-spawn.sh runs before every claude launch.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-wake-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-claude-trust-lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-claude-trust-lib)

file_mode() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null
}

# with_lock <fn> <worktree>: the caller-held-lock contract fm-spawn.sh follows.
with_lock() {
  local fn=$1 wt=$2 lock rc=0
  lock=$(fm_claude_trust_lock_path) || return 1
  fm_claude_trust_lock_acquire "$lock" || return 1
  "$fn" "$wt" || rc=$?
  fm_lock_release "$lock"
  return "$rc"
}

test_creates_file_and_trusts_a_fresh_worktree() {
  local dir wt
  dir="$TMP_ROOT/fresh"
  wt="$dir/some/not-yet-existing/config/wt"
  mkdir -p "$dir/some/not-yet-existing/config" # config dir itself is absent
  CLAUDE_CONFIG_DIR="$dir/some/not-yet-existing/config"
  fm_claude_trust_ensure_dir || fail "ensure_dir failed on an existing parent"
  with_lock fm_claude_pretrust_worktree "$wt" || fail "pretrust failed for a brand-new file"
  assert_present "$CLAUDE_CONFIG_DIR/.claude.json" "no .claude.json was created"
  jq -e . "$CLAUDE_CONFIG_DIR/.claude.json" >/dev/null || fail "created file is not valid JSON"
  [ "$(jq -r --arg p "$wt" '.projects[$p].hasTrustDialogAccepted' "$CLAUDE_CONFIG_DIR/.claude.json")" = true ] \
    || fail "fresh worktree was not marked trusted"
  pass "fm_claude_pretrust_worktree: creates .claude.json and trusts a brand-new worktree"
}

test_private_permissions_and_unique_temp_files() {
  local dir json wt
  dir="$TMP_ROOT/permissions"
  CLAUDE_CONFIG_DIR="$dir/config"
  wt="$dir/wt"
  fm_claude_trust_ensure_dir || fail "ensure_dir failed for permissions test"
  with_lock fm_claude_pretrust_worktree "$wt" || fail "pretrust failed for permissions test"
  json="$CLAUDE_CONFIG_DIR/.claude.json"
  [ "$(file_mode "$CLAUDE_CONFIG_DIR")" = 700 ] || fail "new config directory is not mode 0700"
  [ "$(file_mode "$json")" = 600 ] || fail "new trust file is not mode 0600"
  chmod 0400 "$json"
  with_lock fm_claude_pretrust_worktree "$dir/second-wt" || fail "pretrust failed for a mode 0400 file"
  [ "$(file_mode "$json")" = 400 ] || fail "pretrust weakened an existing mode 0400 file"
  touch "$json.fm-spawn-tmp.preexisting"
  with_lock fm_claude_pretrust_worktree "$dir/third-wt" || fail "a pre-existing similarly named file blocked pretrust"
  assert_present "$json.fm-spawn-tmp.preexisting" "pretrust replaced an unrelated similarly named file"
  pass "fm_claude_pretrust_worktree: uses private unique files and preserves stricter permissions"
}

test_unusable_paths_fail_without_hanging() {
  local dir lock out status original_path
  dir="$TMP_ROOT/unusable"
  CLAUDE_CONFIG_DIR="$dir/config"
  mkdir -p "$CLAUDE_CONFIG_DIR"
  original_path=$PATH
  mkdir -p "$dir/fakebin"
  printf '#!/bin/sh\nexit 1\n' > "$dir/fakebin/mktemp"
  chmod +x "$dir/fakebin/mktemp"
  PATH="$dir/fakebin:$PATH"
  if fm_claude_trust_ensure_dir; then
    PATH=$original_path
    fail "ensure_dir accepted a directory where its write probe failed"
  fi
  PATH=$original_path
  lock=$(fm_claude_trust_lock_path) || fail "could not resolve lock path"
  printf 'not a lock directory\n' > "$lock"
  sleep() { :; }
  fm_claude_trust_lock_acquire "$lock" && fail "bounded acquisition accepted an unusable lock path"
  unset -f sleep
  out=$(timeout 2 bash -c '
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-claude-trust-lib.sh"
    sleep() { :; }
    fm_claude_trust_lock_acquire "$2"
  ' _ "$ROOT" "$lock" 2>&1); status=$?
  [ "$status" -ne 124 ] || fail "trust lock acquisition hung on an unusable lock path"
  [ "$status" -ne 0 ] || fail "trust lock acquisition accepted an unusable lock path"
  pass "claude trust setup: unusable config and lock paths fail in bounded time"
}

test_ensure_dir_creates_a_not_yet_existing_config_dir() {
  # Regression: acquiring the lock before the config dir exists loops forever
  # (fm_lock_try_acquire cd's into the lock's parent to resolve it). This is
  # what fm_claude_trust_ensure_dir exists to prevent - proven here with a
  # bounded `timeout` around the whole sequence a caller must run.
  local dir wt out
  dir="$TMP_ROOT/never-seen"
  wt="$dir/wt"
  CLAUDE_CONFIG_DIR="$dir/config" # does not exist yet
  # shellcheck disable=SC2016  # single quotes are deliberate: these expand in the nested bash -c script, not here
  out=$(timeout 10 bash -c '
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-claude-trust-lib.sh"
    export CLAUDE_CONFIG_DIR="$2"
    fm_claude_trust_ensure_dir || exit 1
    lock=$(fm_claude_trust_lock_path) || exit 1
    fm_claude_trust_lock_acquire "$lock"
    fm_claude_pretrust_worktree "$3"
    status=$?
    fm_lock_release "$lock"
    exit "$status"
  ' _ "$ROOT" "$CLAUDE_CONFIG_DIR" "$wt" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "pretrust into a never-before-seen CLAUDE_CONFIG_DIR did not finish: $out"
  assert_present "$CLAUDE_CONFIG_DIR/.claude.json" "no .claude.json was created for the fresh config dir"
  pass "fm_claude_trust_ensure_dir: a not-yet-existing CLAUDE_CONFIG_DIR is created before locking, not after (no hang)"
}

test_idempotent_and_preserves_unrelated_content() {
  local dir json before after wt1 wt2
  dir="$TMP_ROOT/idempotent"
  mkdir -p "$dir"
  CLAUDE_CONFIG_DIR="$dir"
  json="$dir/.claude.json"
  wt1="$dir/wtA"
  wt2="$dir/wtB"
  # Seed a realistic pre-existing file: unrelated top-level keys, an unrelated
  # already-trusted project with rich history-shaped fields, and an existing
  # UNTRUSTED entry for wt1 carrying its own extra fields that must survive.
  jq -n --arg wt1 "$wt1" --arg wt2 "$wt2" '{
    "userID": "abc123",
    "oauthAccount": {"email": "captain@example.invalid"},
    "projects": {
      ($wt2): {
        "hasTrustDialogAccepted": true,
        "allowedTools": [],
        "lastCost": 1.23,
        "lastModelUsage": {"claude-opus-4-8": {"inputTokens": 5}}
      },
      ($wt1): {
        "hasTrustDialogAccepted": false,
        "allowedTools": ["Bash(git *)"],
        "mcpServers": {"custom": {"type": "http", "url": "https://example.invalid"}}
      }
    }
  }' > "$json"
  before=$(jq -S . "$json")

  with_lock fm_claude_pretrust_worktree "$wt1" || fail "pretrust failed on an already-present entry"

  after=$(jq -S . "$json")
  [ "$(jq -r --arg p "$wt1" '.projects[$p].hasTrustDialogAccepted' "$json")" = true ] \
    || fail "existing untrusted entry was not flipped to trusted"
  [ "$(jq -r --arg p "$wt1" '.projects[$p].allowedTools[0]' "$json")" = 'Bash(git *)' ] \
    || fail "pretrust dropped the existing entry's own allowedTools"
  [ "$(jq -r --arg p "$wt1" '.projects[$p].mcpServers.custom.url' "$json")" = 'https://example.invalid' ] \
    || fail "pretrust dropped the existing entry's own mcpServers"
  [ "$(jq -r '.userID' "$json")" = abc123 ] || fail "pretrust touched an unrelated top-level key"
  [ "$(jq -r --arg p "$wt2" '.projects[$p].lastCost' "$json")" = 1.23 ] \
    || fail "pretrust touched an unrelated project entry"

  # Idempotent: running it again changes nothing further.
  with_lock fm_claude_pretrust_worktree "$wt1" || fail "second pretrust call failed"
  [ "$(jq -S . "$json")" = "$after" ] || fail "a second pretrust call was not a no-op"
  [ "$before" != "$after" ] || fail "the first call should have changed something"
  pass "fm_claude_pretrust_worktree: idempotent, flips only the target entry's trust flag, and never touches unrelated content"
}

test_refuses_malformed_json_without_touching_it() {
  local dir json original
  dir="$TMP_ROOT/malformed"
  mkdir -p "$dir"
  CLAUDE_CONFIG_DIR="$dir"
  json="$dir/.claude.json"
  printf '{ "projects": { not valid json' > "$json"
  original=$(cat "$json")

  if with_lock fm_claude_pretrust_worktree "$dir/wt"; then
    fail "pretrust must refuse malformed JSON, not silently rewrite it"
  fi
  [ "$(cat "$json")" = "$original" ] || fail "a refused pretrust modified the malformed file"
  ls "$dir"/.claude.json.fm-spawn-tmp.* >/dev/null 2>&1 && fail "a refused pretrust left a temp file behind"
  pass "fm_claude_pretrust_worktree: refuses malformed JSON and leaves it byte-for-byte untouched"
}

test_refuses_symlinks_without_touching_them() {
  local dir json target original
  dir="$TMP_ROOT/symlink"
  mkdir -p "$dir/config" "$dir/target"
  CLAUDE_CONFIG_DIR="$dir/config"
  json="$CLAUDE_CONFIG_DIR/.claude.json"
  target="$dir/target/claude.json"
  jq -n '{"projects": {}, "untouched": true}' > "$target"
  original=$(cat "$target")
  ln -s "$target" "$json"

  if with_lock fm_claude_pretrust_worktree "$dir/wt"; then
    fail "pretrust must refuse a symlinked .claude.json"
  fi
  [ -L "$json" ] || fail "a refused pretrust replaced the .claude.json symlink"
  [ "$(readlink "$json")" = "$target" ] || fail "a refused pretrust changed the symlink target"
  [ "$(cat "$target")" = "$original" ] || fail "a refused pretrust modified the symlink target"

  rm "$json"
  ln -s "$dir/target/missing.json" "$json"
  if with_lock fm_claude_pretrust_worktree "$dir/wt"; then
    fail "pretrust must refuse a broken .claude.json symlink"
  fi
  [ -L "$json" ] || fail "a refused pretrust replaced the broken .claude.json symlink"
  assert_absent "$dir/target/missing.json" "a refused pretrust created the broken symlink target"
  ls "$CLAUDE_CONFIG_DIR"/.claude.json.fm-spawn-tmp.* >/dev/null 2>&1 \
    && fail "a refused symlink pretrust left a temp file behind"
  pass "fm_claude_pretrust_worktree: refuses valid and broken symlinks without touching them"
}

test_concurrent_writers_serialize_without_corruption_or_loss() {
  local dir json n pids=() i wt out
  dir="$TMP_ROOT/concurrency"
  mkdir -p "$dir"
  CLAUDE_CONFIG_DIR="$dir"
  json="$dir/.claude.json"
  n=12
  for i in $(seq 1 "$n"); do
    (
      wt="$dir/wt-$i"
      # shellcheck disable=SC2016  # single quotes are deliberate: these expand in the nested bash -c script, not here
      if ! out=$(CLAUDE_CONFIG_DIR="$dir" timeout 15 bash -c '
        . "$1/bin/fm-wake-lib.sh"
        . "$1/bin/fm-claude-trust-lib.sh"
        lock=$(fm_claude_trust_lock_path) || exit 1
        fm_claude_trust_lock_acquire "$lock"
        fm_claude_pretrust_worktree "$2"
        status=$?
        fm_lock_release "$lock"
        exit "$status"
      ' _ "$ROOT" "$wt" 2>&1); then
        echo "$out" > "$dir/fail-$i.log"
        exit 1
      fi
    ) &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do
    wait "$pid" || fail "a concurrent pretrust writer exited non-zero: $(cat "$dir"/fail-*.log 2>/dev/null)"
  done

  jq -e . "$json" >/dev/null || fail "the file is not valid JSON after $n concurrent writers"
  for i in $(seq 1 "$n"); do
    wt="$dir/wt-$i"
    [ "$(jq -r --arg p "$wt" '.projects[$p].hasTrustDialogAccepted' "$json")" = true ] \
      || fail "concurrent writer $i's entry is missing or not trusted - a write was lost"
  done
  ls "$dir"/.claude.json.fm-spawn-tmp.* >/dev/null 2>&1 && fail "a temp file survived concurrent writers"
  pass "fm_claude_pretrust_worktree: $n concurrent writers under the shared lock all land, with no corruption or lost update"
}

test_missing_jq_refuses_loudly() {
  # command -v jq is the first thing fm_claude_pretrust_worktree checks and it
  # returns immediately on a miss, before touching the filesystem, so an empty
  # PATH (no mkdir/mv/rm needed) is enough to prove this path in isolation -
  # the locking and directory-creation contract is covered by the other tests.
  local dir wt out status bash_bin
  dir="$TMP_ROOT/no-jq"
  mkdir -p "$dir"
  wt="$dir/wt"
  bash_bin=$(command -v bash)
  # shellcheck disable=SC2016  # single quotes are deliberate: these expand in the nested bash -c script, not here
  out=$(PATH="$dir/empty-fakebin" "$bash_bin" -c '
    . "$1/bin/fm-claude-trust-lib.sh"
    export CLAUDE_CONFIG_DIR="$2"
    fm_claude_pretrust_worktree "$3"
  ' _ "$ROOT" "$dir" "$wt" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "pretrust without jq on PATH should refuse, not silently skip"
  assert_contains "$out" "jq is required" "missing-jq refusal did not name jq"
  assert_absent "$dir/.claude.json" "a refused pretrust must not create .claude.json"
  pass "fm_claude_pretrust_worktree: refuses loudly when jq is unavailable instead of silently skipping"
}

test_creates_file_and_trusts_a_fresh_worktree
test_private_permissions_and_unique_temp_files
test_unusable_paths_fail_without_hanging
test_ensure_dir_creates_a_not_yet_existing_config_dir
test_idempotent_and_preserves_unrelated_content
test_refuses_malformed_json_without_touching_it
test_refuses_symlinks_without_touching_them
test_concurrent_writers_serialize_without_corruption_or_loss
test_missing_jq_refuses_loudly

echo "# all fm-claude-trust-lib tests passed"
