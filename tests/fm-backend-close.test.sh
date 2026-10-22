#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

check_close() {
  local backend=$1 target=$2 expected=$3 rc=0
  shift 3
  "fm_backend_${backend}_kill_confirmed" "$target" "$@" || rc=$?
  expect_code "$expected" "$rc" "$backend close reported an incorrect stop status"
}

TMP_ROOT=$(fm_test_tmproot fm-backend-close)

# shellcheck disable=SC2329 # Fixture overrides are called through backend dispatch.
(
  . "$ROOT/bin/backends/cmux.sh"
  fm_backend_cmux_window_of_workspace() { printf 'window 2'; }
  fm_backend_cmux_target_ready() { fm_backend_cmux_parse_target "$1"; }
  fm_backend_cmux_scoped_title() { printf '%s' "$1"; }
  fm_backend_cmux_cli() {
    if [ "$1" = list-windows ]; then
      [ "$inventory_status" = 0 ] || return 1
      printf '%s' "$test_windows"
    elif [ "$1 $2" = 'workspace list' ]; then
      [ "$inventory_status" = 0 ] || return 1
      if [ "${7:-}" = other ]; then
        [ "$other_status" = 0 ] || return 1
        [ "$other_malformed" = 0 ] || { printf '{}'; return 0; }
        if [ -e "$TMP_ROOT/present" ]; then
          printf '{"workspaces":[{"id":"%s","title":"fm-task"}]}' "$test_workspace_id"
          return 0
        fi
      fi
      printf '{"workspaces":[]}'
    elif [ "$1" = close-workspace ]; then
      [ "$close_status" = 0 ] || return 1
      [ "$effective" = 0 ] || rm -f "$TMP_ROOT/present"
    else
      return "$close_status"
    fi
  }
  touch "$TMP_ROOT/present"
  test_windows='[{"id":"current"},{"id":"other"}]'
  inventory_status=0 close_status=1 effective=0 other_status=0 other_malformed=0 test_workspace_id=workspace
  check_close cmux workspace:surface 1 '' fm-task
  close_status=0
  check_close cmux workspace:surface 1 '' fm-task
  effective=1
  check_close cmux workspace:surface 0 '' fm-task
  fm_backend_cmux_target_ready() { return 1; }
  check_close cmux workspace:surface 0 '' fm-task
  inventory_status=1
  check_close cmux workspace:surface 1 '' fm-task
  inventory_status=0
  touch "$TMP_ROOT/present"
  check_close cmux workspace:surface 1 '' fm-task
  test_workspace_id=renumbered
  check_close cmux workspace:surface 1 '' fm-task
  fm_backend_cmux_window_of_workspace() { return 0; }
  fm_backend_cmux_target_ready() { fm_backend_cmux_parse_target "$1"; }
  check_close cmux workspace:surface 1 '' fm-task
  rm -f "$TMP_ROOT/present"
  other_status=1
  check_close cmux workspace:surface 1 '' fm-task
  other_status=0 other_malformed=1
  check_close cmux workspace:surface 1 '' fm-task
  other_malformed=0
  check_close cmux workspace:surface 0 '' fm-task
  test_windows=''
  check_close cmux workspace:surface 1 '' fm-task
  test_windows='{}'
  check_close cmux workspace:surface 1 '' fm-task
  test_windows='[]'
  check_close cmux workspace:surface 0 '' fm-task
  fm_backend_cmux_window_of_workspace() { printf 'window 1'; }
  close_status=1
  check_close cmux workspace:surface 1 '' fm-task
) || exit 1
pass "cmux proves absence across every window and refuses incomplete inventories"

# shellcheck disable=SC2329 # Fixture overrides are called through backend dispatch.
(
  . "$ROOT/bin/backends/zellij.sh"
  zellij() { printf 'firstmate\n'; return "$zellij_inventory_status"; }
  fm_backend_zellij_tab_for_pane() { printf '3'; }
  fm_backend_zellij_tab_matches_label() { return "$label_status"; }
  fm_backend_zellij_scoped_title() { printf '%s' "$1"; }
  fm_backend_zellij_cli() {
    case "$3" in
      list-panes) printf '%s' "$test_panes"; return "$read_status" ;;
      list-tabs) printf '%s' "$test_tabs"; return "$read_status" ;;
      *) return "$zellij_close_status" ;;
    esac
  }
  test_panes='[{"id":7}]' test_tabs='[{"tab_id":3,"name":"fm-task"}]' read_status=0
  zellij_inventory_status=0 label_status=0 zellij_close_status=1
  check_close zellij firstmate:7 1 3 fm-task
  check_close zellij firstmate:7 1
  zellij_close_status=0
  check_close zellij firstmate:7 0 3 fm-task
  fm_backend_zellij_tab_for_pane() { return 0; }
  zellij_close_status=1
  check_close zellij firstmate:7 1
  zellij_close_status=0
  check_close zellij firstmate:7 0
  label_status=1
  check_close zellij firstmate:7 1 3 fm-task
  test_panes='[]' test_tabs='[]'
  check_close zellij firstmate:7 0 3 fm-task
  zellij_close_status=1
  check_close zellij firstmate:7 0
  read_status=1
  check_close zellij firstmate:7 1 3 fm-task
  read_status=0 test_panes='{}'
  check_close zellij firstmate:7 1 3 fm-task
  zellij_inventory_status=1
  check_close zellij firstmate:7 1
  zellij() { printf 'other\n'; }
  check_close zellij firstmate:7 0
) || exit 1
pass "zellij distinguishes confirmed absence from failed reads, closes and identity checks"

# shellcheck disable=SC2329 # Fixture overrides are called through backend dispatch.
(
  . "$ROOT/bin/backends/paseo.sh"
  fm_backend_paseo_cli() {
    case "$1 $2" in
      "terminal ls") printf '%s' "$paseo_terminals"; return "$paseo_read_status" ;;
      "terminal kill") return "$paseo_kill_status" ;;
      *) return 0 ;;
    esac
  }
  fm_backend_paseo_terminal_id_for_name() { return 1; }
  fm_backend_paseo_surface_id_for_workspace() { return 1; }
  fm_backend_paseo_scoped_name() { printf '%s' "$1"; }
  fm_backend_paseo_retire_workspace() { :; }
  paseo_read_status=0 paseo_kill_status=0 paseo_terminals='[{"id":"term-1"}]'
  check_close paseo term-1:ws-1 1
  paseo_read_status=1
  check_close paseo term-1:ws-1 1
  paseo_read_status=0 paseo_terminals='[]'
  check_close paseo term-1:ws-1 0
  paseo_terminals='[{"id":"term-1"}]'
  paseo_kill_status=1
  check_close paseo term-1:ws-1 1
) || exit 1
pass "paseo proves its terminal absent from the live inventory and refuses a failed close"

# shellcheck disable=SC2329 # Fixture overrides are called through backend dispatch.
(
  . "$ROOT/bin/backends/orca.sh"
  orca() { printf '%s\n' "$close_response"; return "$orca_close_status"; }
  orca_close_status=1 close_response='{}'
  check_close orca terminal 1
  orca_close_status=0 close_response='{"ok":false}'
  check_close orca terminal 2
  close_response='{"ok":true}'
  check_close orca terminal 0
) || exit 1
pass "orca reports close command and protocol failures while accepting successful closes"
