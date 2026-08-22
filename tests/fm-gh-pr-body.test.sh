#!/usr/bin/env bash
# Behavior tests for bin/fm-gh-pr-body.sh REST publish path.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-gh-pr-body.sh"
COMPAT="$ROOT/bin/fm-gh-pr-compat.sh"
TMP_ROOT=$(fm_test_tmproot fm-gh-pr-body)

test_script_parses() {
  local rc
  bash -n "$TOOL" >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-gh-pr-body.sh must parse cleanly"
  bash -n "$COMPAT" >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-gh-pr-compat.sh must parse cleanly"
  pass "fm-gh-pr-body.sh: bash -n succeeds"
}

test_set_body_uses_rest_patch_not_pr_edit() {
  local fakebin body_file calls
  fakebin="$TMP_ROOT/fakebin"
  calls="$TMP_ROOT/calls"
  mkdir -p "$fakebin"
  body_file="$TMP_ROOT/body.md"
  printf 'signed body\n' > "$body_file"
  cat > "$fakebin/gh" <<'EOF'
#!/usr/bin/env bash
if [ -n "${FM_FAKE_GH_CALLS:-}" ]; then
  printf '%s\n' "$*" >> "$FM_FAKE_GH_CALLS"
fi
if [ "$1" = api ] && [ "$2" = -X ] && [ "$3" = PATCH ]; then
  printf '{"number":88}'
  exit 0
fi
exit 1
EOF
  chmod +x "$fakebin/gh"
  : > "$calls"
  FM_FAKE_GH_CALLS="$calls" \
    PATH="$fakebin:$PATH" \
    "$TOOL" set-body --repo pedromuller-del/firstmate --number 88 --body-file "$body_file" \
    >/dev/null 2>&1 || fail "set-body exited non-zero"
  assert_grep "api -X PATCH repos/pedromuller-del/firstmate/pulls/88" "$calls" \
    "set-body must PATCH the pull request through gh api"
  pass "fm-gh-pr-body.sh: set-body uses REST PATCH instead of gh pr edit"
}

test_compat_pr_edit_routes_through_set_body() {
  local fakebin body_file calls
  fakebin="$TMP_ROOT/compat-fakebin"
  calls="$TMP_ROOT/compat-calls"
  mkdir -p "$fakebin"
  body_file="$TMP_ROOT/compat-body.md"
  printf 'compat body\n' > "$body_file"
  cat > "$fakebin/gh" <<'EOF'
#!/usr/bin/env bash
if [ -n "${FM_FAKE_GH_CALLS:-}" ]; then
  printf '%s\n' "$*" >> "$FM_FAKE_GH_CALLS"
fi
if [ "$1" = api ] && [ "$2" = -X ] && [ "$3" = PATCH ]; then
  printf '{"number":88}'
  exit 0
fi
echo "unexpected gh call: $*" >&2
exit 1
EOF
  chmod +x "$fakebin/gh"
  : > "$calls"
  FM_FAKE_GH_CALLS="$calls" \
    PATH="$fakebin:$PATH" \
    "$COMPAT" pr edit 88 --repo pedromuller-del/firstmate --body-file "$body_file" \
    >/dev/null 2>&1 || fail "compat pr edit exited non-zero"
  assert_grep "api -X PATCH repos/pedromuller-del/firstmate/pulls/88" "$calls" \
    "compat pr edit must route body updates through REST PATCH"
  pass "fm-gh-pr-compat.sh: pr edit body updates avoid gh pr edit GraphQL"
}

test_script_parses
test_set_body_uses_rest_patch_not_pr_edit
test_compat_pr_edit_routes_through_set_body
