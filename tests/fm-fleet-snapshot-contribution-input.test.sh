#!/usr/bin/env bash
# Regression coverage for bin/fm-fleet-snapshot.sh --contribution-input:
# the backlog and task-record JSON must transport through temporary files and
# --slurpfile, not --argjson, because a single --argjson argument is capped by
# the kernel's MAX_ARG_STRLEN (131072 bytes on Linux) and a large enough
# backlog exceeds it, making the kernel refuse to exec jq (issue #5349).
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-snapshot-contribution-input)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  printf '%s\n' "$home"
}

write_large_backlog() {  # <home> <row-count>
  local home=$1 count=$2 i
  {
    printf '## In flight\n'
    for i in $(seq -w 1 "$count"); do
      printf -- '- [ ] task-%s - Task number %s with an intentionally verbose title to pad backlog JSON size for regression testing (repo: alpha) (kind: ship) (priority: 2) (since 2026-07-07)\n' "$i" "$i"
    done
  } > "$home/data/backlog.md"
}

# A fake jq that fails only for the final contribution-input assembly call
# (identified by the exact program text), passing every other invocation
# through to the real jq. Proves the script propagates that failure as a
# non-zero exit instead of the pre-fix behavior of exiting 0 with a broken
# result.
make_failing_assembly_jq_fakebin() {  # <dir>
  local fb real_jq
  fb=$(fm_fakebin "$1")
  real_jq=$(command -v jq) || fail "real jq not found to wrap"
  cat > "$fb/jq" <<SH
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    *'backlog:\$backlog[0],tasks:\$tasks[0]'*)
      echo "jq: simulated contribution-input assembly failure" >&2
      exit 5
      ;;
  esac
done
exec "$real_jq" "\$@"
SH
  chmod +x "$fb/jq"
  printf '%s\n' "$fb"
}

test_contribution_input_survives_large_backlog() {
  local home out backlog_bytes
  home=$(make_home large-backlog)
  # 130 rows produces a backlog JSON well past 131072 bytes (verified against
  # this fixture shape: it reliably reproduces the pre-fix "Argument list too
  # long" failure from /usr/bin/jq on Linux).
  write_large_backlog "$home" 130
  backlog_bytes=$(wc -c < "$home/data/backlog.md")
  [ "$backlog_bytes" -gt 20000 ] || fail "fixture backlog too small to exercise ARG_MAX: $backlog_bytes bytes"

  out=$(FM_HOME="$home" "$SNAPSHOT" --contribution-input)
  local status=$?
  [ "$status" -eq 0 ] || fail "contribution-input exited $status on a large backlog: $out"
  printf '%s' "$out" | jq -e 'has("backlog") and has("tasks")' >/dev/null \
    || fail "contribution-input output missing backlog/tasks keys: $out"
  printf '%s' "$out" | jq -e '.backlog.present == true and (.backlog.records | length) == 130' >/dev/null \
    || fail "contribution-input backlog records incomplete: $out"
  pass "contribution-input transports a large backlog through slurpfile instead of ARG_MAX-capped argjson"
}

test_contribution_input_propagates_jq_failure() {
  local home fakebin out status
  home=$(make_home jq-failure)
  write_large_backlog "$home" 5
  fakebin=$(make_failing_assembly_jq_fakebin "$home")

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --contribution-input 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "contribution-input must not exit 0 when jq assembly fails: $out"
  assert_contains "$out" "fm-fleet-snapshot:" "jq assembly failure must surface an fm-fleet-snapshot error"
  pass "contribution-input propagates a failing jq assembly as a non-zero exit"
}

test_contribution_input_survives_large_backlog
test_contribution_input_propagates_jq_failure
