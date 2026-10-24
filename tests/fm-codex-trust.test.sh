#!/usr/bin/env bash
# Behavior tests for Codex's exact workspace trust registration.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRUST="$ROOT/bin/fm-codex-trust.sh"
TMP_ROOT=$(fm_test_tmproot fm-codex-trust)

make_case() {
  local dir="$TMP_ROOT/$1" project="$TMP_ROOT/$1/project" worktree="$TMP_ROOT/$1/worktree"
  mkdir -p "$dir/codex"
  git init -q "$project"
  git -C "$project" config user.email test@example.invalid
  git -C "$project" config user.name test
  touch "$project/README"
  git -C "$project" add README
  git -C "$project" commit -qm init
  git -C "$project" worktree add -q "$worktree"
  printf '%s|%s|%s|%s\n' "$dir" "$project" "$worktree" "$dir/codex"
}

read_case() {
  IFS='|' read -r CASE_DIR PROJECT WORKTREE CODEX_HOME_DIR <<EOF
$1
EOF
  : "$CASE_DIR"
}

trust_value() {
  python3 - "$1/config.toml" "$2" <<'PY'
import sys
import tomllib
with open(sys.argv[1], "rb") as handle:
    print(tomllib.load(handle)["projects"][sys.argv[2]]["trust_level"])
PY
}

project_field() {
  python3 - "$1/config.toml" "$2" "$3" <<'PY'
import sys
import tomllib
with open(sys.argv[1], "rb") as handle:
    print(tomllib.load(handle)["projects"][sys.argv[2]][sys.argv[3]])
PY
}

config_value() {
  python3 - "$1/config.toml" "$2" <<'PY'
import sys
import tomllib
with open(sys.argv[1], "rb") as handle:
    value = tomllib.load(handle)
for key in sys.argv[2].split('.'):
    value = value[key]
print(value)
PY
}

test_registers_exact_worktree() {
  local rec
  rec=$(make_case fresh)
  read_case "$rec"
  CODEX_HOME="$CODEX_HOME_DIR" "$TRUST" "$WORKTREE" "$PROJECT" >/dev/null \
    || fail "fresh linked worktree trust registration failed"
  [ "$(trust_value "$CODEX_HOME_DIR" "$WORKTREE")" = trusted ] \
    || fail "fresh registration did not trust the exact worktree"
  [ ! -e "$CODEX_HOME_DIR/config.toml.fm-codex-trust" ] \
    || fail "trust registration left a staging file"
  pass "fm-codex-trust: registers a fresh linked worktree"
}

test_preserves_existing_config_and_updates_entry() {
  local rec
  rec=$(make_case update)
  read_case "$rec"
  cat > "$CODEX_HOME_DIR/config.toml" <<EOF
model = "gpt-5"

[projects.'$WORKTREE']
trust_level = "untrusted"
note = "preserve"

[profiles.review]
trust_level = "unrelated"
EOF
  CODEX_HOME="$CODEX_HOME_DIR" "$TRUST" "$WORKTREE" "$PROJECT" >/dev/null \
    || fail "existing Codex config trust update failed"
  [ "$(trust_value "$CODEX_HOME_DIR" "$WORKTREE")" = trusted ] \
    || fail "existing worktree entry was not updated to trusted"
  [ "$(project_field "$CODEX_HOME_DIR" "$WORKTREE" note)" = preserve ] \
    || fail "existing project fields were not preserved"
  [ "$(config_value "$CODEX_HOME_DIR" model)" = "gpt-5" ] \
    || fail "unrelated Codex configuration was not preserved"
  [ "$(config_value "$CODEX_HOME_DIR" "profiles.review.trust_level")" = unrelated ] \
    || fail "unrelated table fields were not preserved"
  pass "fm-codex-trust: preserves and updates an existing project entry"
}

test_inserts_before_following_table() {
  local rec
  rec=$(make_case missing)
  read_case "$rec"
  cat > "$CODEX_HOME_DIR/config.toml" <<EOF
[projects.'$WORKTREE']
note = "preserve"

[profiles.review]
trust_level = "unrelated"
EOF
  CODEX_HOME="$CODEX_HOME_DIR" "$TRUST" "$WORKTREE" "$PROJECT" >/dev/null \
    || fail "missing trust value registration failed"
  [ "$(trust_value "$CODEX_HOME_DIR" "$WORKTREE")" = trusted ] \
    || fail "missing trust value was not inserted"
  [ "$(project_field "$CODEX_HOME_DIR" "$WORKTREE" note)" = preserve ] \
    || fail "project fields were not preserved when trust was missing"
  [ "$(config_value "$CODEX_HOME_DIR" "profiles.review.trust_level")" = unrelated ] \
    || fail "following table was modified when trust was missing"
  pass "fm-codex-trust: inserts trust before a following table"
}

test_rejects_primary_checkout() {
  local rec status=0
  rec=$(make_case primary)
  read_case "$rec"
  CODEX_HOME="$CODEX_HOME_DIR" "$TRUST" "$PROJECT" "$PROJECT" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "primary checkout was accepted as an isolated worktree"
  pass "fm-codex-trust: rejects a primary checkout"
}

test_registers_exact_worktree
test_preserves_existing_config_and_updates_entry
test_inserts_before_following_table
test_rejects_primary_checkout

echo "all fm-codex-trust tests passed"
