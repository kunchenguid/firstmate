#!/usr/bin/env bash
# Story fmops-07 §1 / plan §2.5: the fork engine (nphattai/tasks-axi@0.3.0)
# adds the `--epic` surface to `add`. fm-tasks-axi-lib.sh's compatibility
# probe bumps the floor and adds a fm_tasks_axi_add_has_epic probe so a
# pre-fork stock tasks-axi cannot silently seed an orphan.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-tasks-axi-lib)

fake_tasks_axi() {  # <fakebin-dir> <version> <add-help>
  local dir=$1 version=$2 help=$3
  mkdir -p "$dir"
  # Write the version and add --help text into files the fake reads, then use a
  # quoted heredoc for the static dispatch so the fake's own $1/$2 reach it
  # verbatim without SC2016 single-quote-printf gymnastics. update --help
  # always claims --archive-body and mv --help claims [<id>...] so the pre-
  # existing probes stay green; this fake exercises the epic probe specifically.
  printf '%s\n' "$version" > "$dir/.version"
  printf '%s\n' "$help" > "$dir/.add-help"
  cat > "$dir/tasks-axi" <<'SH'
#!/usr/bin/env bash
here=$(cd "$(dirname "$0")" && pwd)
case "$1" in
  --version) cat "$here/.version" ;;
  add) [ "${2:-}" = "--help" ] && cat "$here/.add-help"; exit 0 ;;
  update) [ "${2:-}" = "--help" ] && echo "--archive-body"; exit 0 ;;
  mv) [ "${2:-}" = "--help" ] && echo "[<id>...]"; exit 0 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$dir/tasks-axi"
}

run_probe() {  # <fakebin-dir>
  local dir=$1
  PATH="$dir:/usr/bin:/bin" bash -c "
    . '$ROOT/bin/fm-tasks-axi-lib.sh'
    fm_tasks_axi_add_has_epic
  "
}

run_compatible() {  # <fakebin-dir>
  local dir=$1
  PATH="$dir:/usr/bin:/bin" bash -c "
    . '$ROOT/bin/fm-tasks-axi-lib.sh'
    fm_tasks_axi_compatible
  "
}

# --- floor is 0.3.0 ---------------------------------------------------------

test_floor_is_030() {
  local floor
  floor=$(bash -c ". '$ROOT/bin/fm-tasks-axi-lib.sh' && printf '%s' \"\$FM_TASKS_AXI_MIN\"")
  [ "$floor" = "0.3.0" ] || fail "FM_TASKS_AXI_MIN is $floor, expected 0.3.0"
  pass "FM_TASKS_AXI_MIN is 0.3.0 (fork engine floor)"
}

# --- --epic probe -----------------------------------------------------------

test_epic_probe_passes_on_fork_help() {
  local dir="$TMP_ROOT/fork"
  fake_tasks_axi "$dir" "0.3.0" "add [options]
Options:
  --epic <slug>      required epic membership
  --child-of <id>    decision-hold escape"
  run_probe "$dir" || fail "epic probe failed on fork-shaped help"
  pass "fm_tasks_axi_add_has_epic passes when add --help mentions --epic"
}

test_epic_probe_fails_on_stock_help() {
  local dir="$TMP_ROOT/stock"
  fake_tasks_axi "$dir" "0.2.5" "add [options]
Options:
  --kind <kind>
  --repo <repo>
  --report <path>"
  local rc=0
  run_probe "$dir" || rc=$?
  [ "$rc" -ne 0 ] || fail "epic probe passed on stock 0.2.5 add --help"
  pass "fm_tasks_axi_add_has_epic fails on pre-fork add --help"
}

# --- compatibility gate: version + probe -----------------------------------

test_compat_gate_passes_on_030_with_epic() {
  local dir="$TMP_ROOT/compat-fork"
  fake_tasks_axi "$dir" "0.3.0" "add [options]
Options:
  --epic <slug>"
  run_compatible "$dir" || fail "fork 0.3.0 with --epic help must be compatible"
  pass "compatible: 0.3.0 with --epic in add help"
}

test_compat_gate_fails_on_030_without_epic_help() {
  local dir="$TMP_ROOT/compat-no-epic"
  fake_tasks_axi "$dir" "0.3.0" "add [options]
Options:
  --kind
  --repo"
  local rc=0
  run_compatible "$dir" || rc=$?
  [ "$rc" -ne 0 ] || fail "compatibility gate passed on 0.3.0 without --epic help"
  pass "incompatible: 0.3.0 that lacks --epic in add help fails the gate"
}

test_compat_gate_fails_on_stock_025() {
  local dir="$TMP_ROOT/compat-stock"
  fake_tasks_axi "$dir" "0.2.5" "add [options]"
  local rc=0
  run_compatible "$dir" || rc=$?
  [ "$rc" -ne 0 ] || fail "compatibility gate passed on stock 0.2.5"
  pass "incompatible: stock 0.2.5 fails the compatibility gate"
}

test_floor_is_030
test_epic_probe_passes_on_fork_help
test_epic_probe_fails_on_stock_help
test_compat_gate_passes_on_030_with_epic
test_compat_gate_fails_on_030_without_epic_help
test_compat_gate_fails_on_stock_025
