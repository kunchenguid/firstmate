#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-sol-cap-rex)

test_rex_absence_reconciliation() (
  local case_dir state raw proof phase
  case_dir=$TMP_ROOT
  mkdir -p "$case_dir/home/state" "$case_dir/home/config"
  printf "max=1\nmodels=gpt-6.1-sol\n" > "$case_dir/home/config/sol-cap"
  state=$case_dir/home/state
  FM_HOME=$case_dir/home
  . "$ROOT/bin/fm-wake-lib.sh"
  . "$ROOT/bin/fm-secondmate-registry-lib.sh"
  . "$ROOT/bin/fm-sol-cap-lib.sh"
  . "$ROOT/bin/fm-control-lib.sh"
  fm_backend_of_meta() { printf rex; }
  fm_backend_target_of_meta() { printf session:block; }
  fm_meta_get() { awk -F= -v key="$2" '$1 == key { print $2; exit }' "$1"; }
  fm_backend_source() { :; }
  fm_backend_agent_state() { printf '%s' "$raw"; }
  fm_backend_rex_endpoint_absence_recheck() {
    [ "$1" = session:block ] && [ "$2" = recorded-server ] || return 1
    printf '%s' "$proof"
  }
  fm_write_meta "$state/rex-task.meta" "backend=rex" "window=session:block" \
    "rex_server=recorded-server" "model=gpt-6.1-sol"
  for phase in adopt reconcile; do
    for raw in missing unreadable; do
      for proof in unreadable alive missing; do
        : > "$state/sol-sessions.tsv"
        printf "rex-task\tgpt-6.1-sol\t1\t-2\n" > "$state/sol-sessions.tsv"
        if [ "$phase" = adopt ]; then
          fm_sol_cap_config "$FM_HOME/config" || fail "declaration failed"
          fm_sol_cap_active_count "$state" || fail "Rex adoption failed"
        else
          fm_sol_cap_reconcile_local rex-task "$state" || fail "Rex reconciliation failed"
        fi
        if [ "$proof" = missing ]; then
          assert_equals -1 "$(awk -F "\t" '$1 == "rex-task" { print $4 }' "$state/sol-sessions.tsv")" "Rex absence did not release occupancy"
        else
          assert_equals -2 "$(awk -F "\t" '$1 == "rex-task" { print $4 }' "$state/sol-sessions.tsv")" "unproven Rex absence released occupancy"
        fi
      done
    done
  done
  pass "Rex adoption and reconciliation prove absence on the recorded server"
)


test_rex_absence_reconciliation
