#!/usr/bin/env bash
# Behavior test: `fm-captain-hold.sh open` must answer on a non-markdown backlog.
#
# A tasks-axi that ships the markdown backend only refuses a beads-backed home
# with "Unsupported backend". That adapter can neither record nor read a captain
# hold there, so a task is provably NOT held. `open` used to exit 2 ("cannot
# tell") there, which wedged every caller that gates on its answer: teardown,
# local merge, PR merge, and the bearings board all refused, so on such a home
# nothing could ever be cleaned up or merged.
#
# A beads-capable tasks-axi still answers through the row probe: a held row is
# still 0 and an unreadable row is still 2. The markdown home's existing answers
# must not change: an absent task is still 1 (or 3 with --distinguish-absent).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HOLD="$ROOT/bin/fm-captain-hold.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-hold-backend)

# A home whose backlog is beads-backed. The backend is declared in the data
# root's .tasks.toml, which is where the resolver reads it from.
make_beads_home() {  # <home>
  local home=$1 graph="$TMP_ROOT/beads-graph"
  mkdir -p "$home/config" "$home/data" "$home/state" "$home/fakebin" "$graph"
  cat >"$home/.tasks.toml" <<TOML
backend = "beads"
[beads]
binary = "bd"
path = "$graph"
prefix = "test"
TOML
}

# A tasks-axi whose `show` answers with <show-mode>:
#   unsupported - the markdown-only adapter's refusal of a beads home
#   held        - a beads-capable adapter reading a captain-held row
#   broken      - a beads-capable adapter that cannot read the row
write_tasks_axi_stub() {  # <fakebin> <show-mode>
  local fb=$1 mode=$2
  cat >"$fb/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf '%s\n' '0.2.6' ;;
  show)
    case "@MODE@" in
      unsupported)
        printf '%s\n' 'error: "Unsupported backend \"beads\" — P1 ships the markdown backend only"' >&2
        exit 1
        ;;
      held)
        printf '%s\n' 'task:' "  id: $2" '  state: queued' '  held: yes' '  blocked: no' \
          '  hold_kind: captain' '  body: ""'
        ;;
      *)
        printf '%s\n' 'error: bd exited 1: database is locked' >&2
        exit 1
        ;;
    esac
    ;;
  *) exit 1 ;;
esac
SH
  sed -i.bak "s%@MODE@%$mode%" "$fb/tasks-axi"
  rm -f "$fb/tasks-axi.bak"
  chmod +x "$fb/tasks-axi"
}

hold_status() { # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" \
    FM_TASKS_AXI_COMPATIBLE=1 \
    FM_HOME="$home" \
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    "$HOLD" open "$@" >/dev/null 2>&1
  printf '%s' $?
}

test_unsupported_backend_is_provably_not_held() {
  local home="$TMP_ROOT/unsupported" status
  make_beads_home "$home"
  write_tasks_axi_stub "$home/fakebin" unsupported
  status=$(hold_status "$home" some-task)
  [ "$status" = 1 ] || fail "a backend the adapter cannot address must answer 'not held' (1), got $status"
  status=$(hold_status "$home" some-task --distinguish-absent)
  [ "$status" = 3 ] || fail "a backend the adapter cannot address must answer absent (3) under --distinguish-absent, got $status"
  pass "captain-hold open: an unsupported non-markdown backend answers 'not held' (1, or 3 with --distinguish-absent)"
}

test_beads_capable_adapter_still_reports_a_hold() {
  local home="$TMP_ROOT/held" status
  make_beads_home "$home"
  write_tasks_axi_stub "$home/fakebin" held
  status=$(hold_status "$home" some-task)
  [ "$status" = 0 ] || fail "a captain-held beads row must still answer held (0), got $status"
  pass "captain-hold open: a beads-capable adapter still reports a captain hold"
}

test_beads_read_failure_is_still_cannot_tell() {
  local home="$TMP_ROOT/broken" status
  make_beads_home "$home"
  write_tasks_axi_stub "$home/fakebin" broken
  status=$(hold_status "$home" some-task)
  [ "$status" = 2 ] || fail "an unreadable beads row may hide a hold and must answer 2, got $status"
  status=$(hold_status "$home" some-task --distinguish-absent)
  [ "$status" = 2 ] || fail "an unreadable beads row must answer 2 under --distinguish-absent, got $status"
  pass "captain-hold open: a beads read failure still answers 'cannot tell'"
}

test_markdown_home_answers_are_unchanged() {
  local home="$TMP_ROOT/markdown" status
  mkdir -p "$home/config" "$home/data" "$home/state" "$home/fakebin"
  printf 'backend = "markdown"\n' >"$home/.tasks.toml"
  # No backlog file at all: this home records no calls, so an absent task is 1.
  status=$(hold_status "$home" absent-task)
  [ "$status" = 1 ] || fail "a markdown home with no backlog file must still answer 1, got $status"
  status=$(hold_status "$home" absent-task --distinguish-absent)
  [ "$status" = 3 ] || fail "a markdown home with no backlog file must still answer 3 for absent, got $status"
  pass "captain-hold open: markdown-home answers are unchanged (1 absent, 3 absent+distinguish)"
}

test_unsupported_backend_is_provably_not_held
test_beads_capable_adapter_still_reports_a_hold
test_beads_read_failure_is_still_cannot_tell
test_markdown_home_answers_are_unchanged
