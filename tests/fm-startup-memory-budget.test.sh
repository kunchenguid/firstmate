#!/usr/bin/env bash
# Behavioral coverage for the visible startup-memory budget, its safe parser,
# and accounting command.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-startup-memory-budget)
BUDGET="$ROOT/bin/fm-startup-memory-budget.sh"
BOOTSTRAP="$ROOT/bin/fm-bootstrap.sh"

make_fake_toolchain() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" node chrome-devtools-axi
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' '0.1.29'
fi
exit 0
SH
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'quota-axi 0.1.29 (fake)'
fi
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease]'
fi
SH
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'no-mistakes version v1.46.0 (fake)'
fi
SH
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}:${2:-}" in
  --version:*) printf '%s\n' '0.2.4' ;;
  update:--help) printf '%s\n' '--archive-body' ;;
  mv:--help) printf '%s\n' 'usage: tasks-axi mv <id> [<id>...]' ;;
esac
SH
  fm_test_fake_herdr_send "$fakebin"
  chmod +x "$fakebin"/*
  printf '%s\n' "$fakebin"
}

new_bootstrap_world() {
  local name=$1 world root home
  world="$TMP_ROOT/$name"
  root="$world/root"
  home="$world/home"
  mkdir -p "$home/config" "$home/data" "$home/state" "$root/bin"
  git init -q -b main "$root"
  printf '%s\n' 'config/' > "$root/.gitignore"
  printf '%s\n' '# Firstmate test root' > "$root/AGENTS.md"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$root/bin/placeholder.sh"
  chmod +x "$root/bin/placeholder.sh"
  git -C "$root" add -A
  git -C "$root" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -qm initial
  printf '%s|%s\n' "$root" "$home"
}

run_bootstrap() {
  local root=$1 home=$2 fakebin=$3
  PATH="$fakebin:$BASE_PATH" FM_BACKEND=herdr FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    "$BOOTSTRAP"
}

test_primary_bootstrap_materializes_visible_default() {
  local rec root home fakebin out
  rec=$(new_bootstrap_world materialize)
  root=${rec%%|*}
  home=${rec#*|}
  fakebin=$(make_fake_toolchain "$TMP_ROOT/materialize")

  out=$(run_bootstrap "$root" "$home" "$fakebin")
  [ -z "$out" ] || fail "default materialization should stay quiet, got: $out"
  [ "$(<"$home/config/startup-memory-budget")" = 7500 ] \
    || fail "bootstrap did not materialize the visible 7500 default"
  [ "$(FM_HOME="$home" "$BUDGET" read)" = 7500 ] \
    || fail "read command did not expose the generated default"

  printf '321\n' > "$home/config/startup-memory-budget"
  run_bootstrap "$root" "$home" "$fakebin" >/dev/null
  [ "$(<"$home/config/startup-memory-budget")" = 321 ] \
    || fail "bootstrap replaced a valid captain-selected budget"
  pass "primary bootstrap materializes the visible default and preserves valid captain choices"
}

expect_rejected_read() {
  local home=$1 expected=$2 out rc
  set +e
  out=$(FM_HOME="$home" "$BUDGET" read 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "unsafe budget unexpectedly parsed: $expected"
  assert_contains "$out" "$expected" "unsafe budget rejection was not specific"
}

test_safe_parser_rejects_ambiguous_and_unsafe_values() {
  local home outside
  home="$TMP_ROOT/parser-home"
  mkdir -p "$home/config" "$home/data"
  printf '42\n' > "$home/config/startup-memory-budget"
  [ "$(FM_HOME="$home" "$BUDGET" read)" = 42 ] || fail "valid positive decimal budget was rejected"

  printf '0\n' > "$home/config/startup-memory-budget"
  expect_rejected_read "$home" 'value must be one positive decimal integer'
  printf '42\nextra\n' > "$home/config/startup-memory-budget"
  expect_rejected_read "$home" 'value must be one positive decimal integer'
  printf '+42\n' > "$home/config/startup-memory-budget"
  expect_rejected_read "$home" 'value must be one positive decimal integer'

  outside="$TMP_ROOT/parser-outside"
  printf '77\n' > "$outside"
  rm -f "$home/config/startup-memory-budget"
  ln -s "$outside" "$home/config/startup-memory-budget"
  expect_rejected_read "$home" 'file is symlinked'
  [ "$(<"$outside")" = 77 ] || fail "symlink rejection changed its external target"

  rm -f "$home/config/startup-memory-budget"
  ln "$outside" "$home/config/startup-memory-budget"
  expect_rejected_read "$home" 'file is hardlinked'
  [ "$(<"$outside")" = 77 ] || fail "hardlink rejection changed its external source"

  rm -f "$home/config/startup-memory-budget"
  rm -rf "$home/config"
  ln -s "$TMP_ROOT/parser-config-target" "$home/config"
  mkdir -p "$TMP_ROOT/parser-config-target"
  printf '88\n' > "$TMP_ROOT/parser-config-target/startup-memory-budget"
  expect_rejected_read "$home" 'config directory is symlinked'
  pass "budget parser accepts one exact positive value and rejects malformed or unsafe inputs"
}

test_budget_accounting_reports_all_three_files_and_safe_failure() {
  local home out rc outside
  home="$TMP_ROOT/accounting-home"
  mkdir -p "$home/config" "$home/data"
  printf '10\n' > "$home/config/startup-memory-budget"
  printf 'abc\n' > "$home/data/captain.md"

  out=$(FM_HOME="$home" "$BUDGET" report)
  assert_contains "$out" 'estimator=ceil(UTF-8 bytes / 3) conservative-local-estimate' \
    "report did not name the stable estimator"
  assert_contains "$out" 'file=data/captain.md bytes=4 estimated_tokens=2 status=present' \
    "report did not account for captain memory"
  assert_contains "$out" 'file=data/learnings.md bytes=0 estimated_tokens=0 status=absent' \
    "report did not account for absent learnings"
  assert_contains "$out" 'total_estimated_tokens=2' "report total was not the sum of retained memory files"
  assert_contains "$out" 'budget_status=within-budget' "report did not classify the initial total"

  printf 'abcdefabcdefabcdefabcdef\n' > "$home/data/learnings.md"
  out=$(FM_HOME="$home" "$BUDGET" report)
  assert_contains "$out" 'budget_status=over-budget' "report did not surface an over-budget total"

  outside="$TMP_ROOT/accounting-outside"
  printf 'outside\n' > "$outside"
  rm -f "$home/data/captain.md"
  ln -s "$outside" "$home/data/captain.md"
  set +e
  out=$(FM_HOME="$home" "$BUDGET" report 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "unsafe memory input should fail the accounting command"
  assert_contains "$out" 'memory file is not an ordinary regular file' \
    "accounting failure did not identify the unsafe memory file"
  [ "$(<"$outside")" = outside ] || fail "accounting failure changed a symlink target"
  pass "budget accounting sums the retained startup files and reports safe failures"
}






test_primary_bootstrap_materializes_visible_default
test_safe_parser_rejects_ambiguous_and_unsafe_values
test_budget_accounting_reports_all_three_files_and_safe_failure

echo '# all fm-startup-memory-budget tests passed'
