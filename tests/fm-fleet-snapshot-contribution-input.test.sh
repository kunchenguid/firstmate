#!/usr/bin/env bash
# Regression coverage for bin/fm-fleet-snapshot.sh --contribution-input:
# a failing final jq assembly must exit non-zero instead of exiting 0 with
# empty output (issue #5349).
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

write_backlog() {  # <home>
  printf '%s\n' '## In flight' \
    '- [ ] task-1 - Test task (repo: alpha) (kind: ship) (priority: 2) (since 2026-07-07)' \
    > "$1/data/backlog.md"
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

test_contribution_input_propagates_jq_failure() {
  local home fakebin out status
  home=$(make_home jq-failure)
  write_backlog "$home"
  fakebin=$(make_failing_assembly_jq_fakebin "$home")

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --contribution-input 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "contribution-input must not exit 0 when jq assembly fails: $out"
  assert_contains "$out" "fm-fleet-snapshot: contribution input assembly failed" "jq assembly failure must surface an fm-fleet-snapshot error"
  pass "contribution-input propagates a failing jq assembly as a non-zero exit"
}

test_contribution_input_propagates_jq_failure
