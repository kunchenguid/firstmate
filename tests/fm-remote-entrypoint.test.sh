#!/usr/bin/env bash
# fm-remote-entrypoint.sh installs as a PATH symlink under ~/.local/bin
# (docs/remote-secondmates.md). SCRIPT_DIR must resolve to the real bin/
# directory so it can source its sibling fm-remote-job-lib.sh, not to the
# symlink's own directory.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-remote-entrypoint)
REAL_BIN="$TMP_ROOT/real-root/bin"
LOCAL_BIN="$TMP_ROOT/local-bin"
SHADOW_BIN="$TMP_ROOT/shadow-bin"
mkdir -p "$REAL_BIN" "$LOCAL_BIN" "$SHADOW_BIN"
cp "$ROOT/bin/fm-remote-entrypoint.sh" "$ROOT/bin/fm-remote-job-lib.sh" "$REAL_BIN/"
chmod +x "$REAL_BIN/fm-remote-entrypoint.sh"
ln -s "$REAL_BIN/fm-remote-entrypoint.sh" "$LOCAL_BIN/fm-remote-entrypoint.sh"

run_entrypoint() { # <path> <stdout-file> <stderr-file> [args...]
  local path=$1 out=$2 err=$3 code
  shift 3
  "$path" "$@" >"$out" 2>"$err"
  code=$?
  printf '%s' "$code"
}

entrypoint_base64() { # <text>
  local base64_bin tr_bin
  if [ -x /usr/bin/base64 ]; then base64_bin=/usr/bin/base64; elif [ -x /bin/base64 ]; then base64_bin=/bin/base64; else fail "system base64 is unavailable"; fi
  if [ -x /usr/bin/tr ]; then tr_bin=/usr/bin/tr; elif [ -x /bin/tr ]; then tr_bin=/bin/tr; else fail "system tr is unavailable"; fi
  printf '%s' "$1" | "$base64_bin" | "$tr_bin" -d '\n'
}

test_symlink_invocation_resolves_sibling_lib() {
  local out err code
  out="$TMP_ROOT/symlink.stdout"
  err="$TMP_ROOT/symlink.stderr"
  code=$(run_entrypoint "$LOCAL_BIN/fm-remote-entrypoint.sh" "$out" "$err")

  # A wrong SCRIPT_DIR fails while sourcing the sibling lib, before argv is
  # even checked, with a "No such file or directory" source error and exit 1.
  # Reaching the die() for missing protocol args proves the sibling lib
  # sourced from the real bin/, not from the symlink's own directory.
  assert_no_grep 'No such file or directory' "$err" \
    "invoking fm-remote-entrypoint.sh through a symlink failed to source its sibling lib"
  expect_code 64 "$code" "symlink invocation exit code"
  assert_grep 'remote entrypoint expects protocol, root, home, and argv' "$err" \
    "symlink invocation did not reach argument validation past sibling-lib sourcing"
  pass "fm-remote-entrypoint.sh invoked via a PATH symlink resolves SCRIPT_DIR to the real bin/ directory"
}

test_direct_invocation_still_works() {
  # Control: the same real script invoked directly (no symlink) must behave
  # identically, so the symlink coverage above is proven by contrast.
  local out err code
  out="$TMP_ROOT/direct.stdout"
  err="$TMP_ROOT/direct.stderr"
  code=$(run_entrypoint "$REAL_BIN/fm-remote-entrypoint.sh" "$out" "$err")

  expect_code 64 "$code" "direct invocation exit code"
  assert_grep 'remote entrypoint expects protocol, root, home, and argv' "$err" \
    "direct invocation did not reach argument validation"
  pass "fm-remote-entrypoint.sh invoked directly still resolves SCRIPT_DIR correctly"
}

test_bootstrap_uses_system_tools_before_operator_path() {
  local out err code marker root_arg home_arg argv_arg home
  out="$TMP_ROOT/shadow.stdout"
  err="$TMP_ROOT/shadow.stderr"
  marker="$TMP_ROOT/shadow-tool-ran"
  home="$TMP_ROOT/home"
  mkdir -p "$home"
  for tool in wc base64 dirname; do
    cat > "$SHADOW_BIN/$tool" <<SH
#!/usr/bin/env bash
printf '%s\\n' '$tool' >> '$marker'
exit 42
SH
    chmod +x "$SHADOW_BIN/$tool"
  done

  root_arg=$(entrypoint_base64 "$TMP_ROOT/missing-root")
  home_arg=$(entrypoint_base64 "$home")
  argv_arg=$(entrypoint_base64 'fm-remote-doctor.sh')
  code=$(PATH="$SHADOW_BIN:$PATH" run_entrypoint "$REAL_BIN/fm-remote-entrypoint.sh" "$out" "$err" 1 "$root_arg" "$home_arg" "$argv_arg")

  expect_code 64 "$code" "shadowed tool bootstrap exit code"
  assert_grep 'remote root is not a safe existing directory' "$err" \
    "entrypoint did not decode arguments before rejecting the missing root"
  assert_absent "$marker" "entrypoint ran an account PATH tool during bootstrap"
  pass "fm-remote-entrypoint.sh uses system tools before composing the operator PATH"
}

test_symlink_invocation_resolves_sibling_lib
test_direct_invocation_still_works
test_bootstrap_uses_system_tools_before_operator_path
