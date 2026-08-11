#!/usr/bin/env bash
# fm-command-execution.test.sh - command execution adapters and task journal.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot command-execution)
STATE="$TMP_ROOT/state"
WORKTREE="$TMP_ROOT/worktree"
mkdir -p "$STATE" "$WORKTREE"
WORKTREE=$(cd "$WORKTREE" && pwd -P)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
CRABBOX_LOG="$TMP_ROOT/crabbox.log"
: > "$CRABBOX_LOG"
chmod 600 "$CRABBOX_LOG"
export CRABBOX_LOG CRABBOX_RUN_STATUS=0 CRABBOX_STOP_STATUS=0 CRABBOX_NONOBJECT=0 CRABBOX_MULTIDOC=0

cat > "$FAKEBIN/crabbox" <<'SH'
#!/usr/bin/env bash
set -u
printf 'argv:' >> "$CRABBOX_LOG"
printf ' %q' "$@" >> "$CRABBOX_LOG"
printf '\n' >> "$CRABBOX_LOG"
case "${1:-}" in
  doctor)
    printf 'crabbox-ready\n'
    ;;
  run)
    case "${2:-}" in
      --profile|--id) ;;
      *)
        printf 'unsupported Crabbox run routing\n' >&2
        exit 64
        ;;
    esac
    printf 'crabbox-stdout\n'
    printf 'crabbox-stderr\n' >&2
    exit "${CRABBOX_RUN_STATUS:-0}"
    ;;
  status)
    if [ "${CRABBOX_MULTIDOC:-0}" = 1 ]; then
      printf '{}\n{}\n'
    elif [ "${CRABBOX_NONOBJECT:-0}" = 1 ]; then
      printf '["not-an-object"]\n'
    else
      printf '{"id":"%s","cost":12.5,"expires_at":"2099-01-02T03:04:05Z","state":"running"}\n' "${3:-}"
    fi
    ;;
  logs)
    printf 'logs-for-%s\n' "${2:-}"
    ;;
  stop)
    exit "${CRABBOX_STOP_STATUS:-0}"
    ;;
  *)
    printf 'unexpected fake Crabbox command\n' >&2
    exit 64
    ;;
esac
SH
chmod +x "$FAKEBIN/crabbox"
export PATH="$FAKEBIN:$PATH"

# shellcheck source=bin/fm-command-execution.sh
. "$ROOT/bin/fm-command-execution.sh"

RUN_OUT="$TMP_ROOT/run.out"
RUN_ERR="$TMP_ROOT/run.err"
RUN_STATUS=0
run_cli() {
  : > "$RUN_OUT"
  : > "$RUN_ERR"
  if FM_STATE_OVERRIDE="$STATE" FM_HOME="$TMP_ROOT" FM_ROOT_OVERRIDE="$TMP_ROOT" \
    "$ROOT/bin/fm-exec.sh" "$@" >"$RUN_OUT" 2>"$RUN_ERR"; then
    RUN_STATUS=0
  else
    RUN_STATUS=$?
  fi
  RUN_STDOUT=$(cat "$RUN_OUT")
  RUN_STDERR=$(cat "$RUN_ERR")
}

run_function() {
  : > "$RUN_OUT"
  : > "$RUN_ERR"
  if "$@" >"$RUN_OUT" 2>"$RUN_ERR"; then
    RUN_STATUS=0
  else
    RUN_STATUS=$?
  fi
  RUN_STDOUT=$(cat "$RUN_OUT")
  RUN_STDERR=$(cat "$RUN_ERR")
}

write_local_meta() {
  local id=$1
  fm_write_meta "$STATE/$id.meta" "worktree=$WORKTREE"
}

write_crabbox_meta() {
  local id=$1 profile=${2:-batch-profile}
  fm_write_meta "$STATE/$id.meta" \
    "worktree=$WORKTREE" \
    'executor=crabbox' \
    "executor_profile=$profile"
}

journal_has() {
  local id=$1 query=$2
  jq -s -e "$query" "$STATE/$id.execution" >/dev/null 2>&1 || \
    fail "journal assertion failed for $id: $query"
}

# Local execution remains transparent: argv, cwd, stdout, stderr, and status
# all cross the adapter without a provider-routing interpretation.
cat > "$WORKTREE/argv-probe.sh" <<'SH'
#!/usr/bin/env bash
printf 'cwd=%s arg1=<%s> arg2=<%s>\n' "$PWD" "${1-}" "${2-}"
printf 'diagnostic=<%s>\n' "${1-}" >&2
exit 37
SH
chmod +x "$WORKTREE/argv-probe.sh"
run_function fm_command_execution_run local "$WORKTREE" '' '' "$WORKTREE/argv-probe.sh" 'secret argv' 'wild*value'
expect_code 37 "$RUN_STATUS" 'local adapter preserves command exit status'
assert_contains "$RUN_STDOUT" "cwd=$WORKTREE arg1=<secret argv> arg2=<wild*value>" 'local adapter preserves argv and cwd on stdout'
assert_contains "$RUN_STDERR" 'diagnostic=<secret argv>' 'local adapter preserves stderr'

# Routing is explicit and rejects every ambiguous profile/lease combination,
# including unknown executors and warm-preparation requests with no lease handle.
run_function fm_command_execution_run local "$WORKTREE" profile '' true
[ "$RUN_STATUS" -ne 0 ] || fail 'local profile routing was accepted'
assert_contains "$RUN_STDERR" 'requires empty profile and lease' 'local profile refusal is explicit'
run_function fm_command_execution_run local "$WORKTREE" '' lease-a true
[ "$RUN_STATUS" -ne 0 ] || fail 'local lease routing was accepted'
assert_contains "$RUN_STDERR" 'requires empty profile and lease' 'local lease refusal is explicit'
run_function fm_command_execution_run crabbox "$WORKTREE" profile lease-a true
[ "$RUN_STATUS" -ne 0 ] || fail 'Crabbox profile-plus-lease routing was accepted'
assert_contains "$RUN_STDERR" 'requires exactly one nonempty routing axis' 'Crabbox ambiguous routing refusal is explicit'
run_function fm_command_execution_run crabbox "$WORKTREE" '' '' true
[ "$RUN_STATUS" -ne 0 ] || fail 'Crabbox no-routing execution was accepted'
run_function fm_command_execution_check unsupported
[ "$RUN_STATUS" -ne 0 ] || fail 'unknown executor selected an ambiguous fallback'
assert_contains "$RUN_STDERR" "unknown command executor 'unsupported'" 'unknown executor refusal is explicit'
run_function fm_command_execution_prepare local profile
[ "$RUN_STATUS" -ne 0 ] || fail 'local profile preparation was accepted'
run_function fm_command_execution_prepare crabbox profile
[ "$RUN_STATUS" -ne 0 ] || fail 'Crabbox warm preparation created an unrecordable lease'
assert_contains "$RUN_STDERR" 'warm preparation is unavailable' 'Crabbox prewarm refusal is explicit'

# The adapter emits the two documented Crabbox forms, with no local fallback.
: > "$CRABBOX_LOG"
run_function fm_command_execution_run crabbox "$WORKTREE" profile-a '' printf profile-command
expect_code 0 "$RUN_STATUS" 'Crabbox profile command succeeds'
assert_contains "$RUN_STDOUT" 'crabbox-stdout' 'Crabbox profile command streams stdout'
assert_contains "$RUN_STDERR" 'crabbox-stderr' 'Crabbox profile command streams stderr'
assert_grep 'argv: run --profile profile-a -- printf profile-command' "$CRABBOX_LOG" 'Crabbox profile form is exact'
run_function fm_command_execution_run crabbox "$WORKTREE" '' lease-direct printf lease-command
expect_code 0 "$RUN_STATUS" 'Crabbox lease command succeeds'
assert_grep 'argv: run --id lease-direct -- printf lease-command' "$CRABBOX_LOG" 'Crabbox lease form is exact'

# A local task records only lifecycle facts, never argv or command output.
write_local_meta local-task
run_cli local-task run -- "$WORKTREE/argv-probe.sh" 'journal-secret-argv'
expect_code 37 "$RUN_STATUS" 'task-local command preserves exit status'
assert_contains "$RUN_STDOUT" 'journal-secret-argv' 'task-local command returns command stdout'
assert_contains "$RUN_STDERR" 'journal-secret-argv' 'task-local command returns command stderr'
assert_present "$STATE/local-task.execution" 'task-local journal is created'
journal_has local-task 'length == 2 and .[0].event == "run-start" and .[1].event == "run-finish" and .[1].exit_code == 37 and all(.[]; .task == "local-task" and .run_id != null)'
journal=$(cat "$STATE/local-task.execution")
assert_not_contains "$journal" 'journal-secret-argv' 'execution journal excludes argv and output'
assert_not_contains "$journal" 'diagnostic=' 'execution journal excludes command output'
run_cli local-task run --lease local-lease -- true
[ "$RUN_STATUS" -ne 0 ] || fail 'fm-exec accepted a local lease'
assert_contains "$RUN_STDERR" 'local execution does not accept a lease' 'fm-exec local lease refusal is explicit'

# A profile-routed task calls Crabbox through fm-exec and logs require an
# explicit caller-supplied run identifier.
write_crabbox_meta profile-task profile-a
run_cli profile-task check
expect_code 0 "$RUN_STATUS" 'Crabbox task check succeeds through fake CLI'
assert_contains "$RUN_STDOUT" 'crabbox-ready' 'Crabbox task check streams provider readiness'
run_cli profile-task run -- printf profile-task-command
expect_code 0 "$RUN_STATUS" 'profile-routed task command succeeds'
assert_grep 'argv: run --profile profile-a -- printf profile-task-command' "$CRABBOX_LOG" 'fm-exec emits profile command form'
journal_has profile-task '.[0].profile == "profile-a" and .[0].lease == null and .[1].exit_code == 0'
run_cli profile-task logs explicit-run-id
expect_code 0 "$RUN_STATUS" 'explicit task run logs succeed'
assert_contains "$RUN_STDOUT" 'logs-for-explicit-run-id' 'explicit run ID reaches Crabbox logs'
run_cli profile-task logs
[ "$RUN_STATUS" -ne 0 ] || fail 'logs without an explicit run ID were accepted'
assert_contains "$RUN_STDERR" 'usage: fm-exec.sh' 'logs require an explicit run ID'

# Lease folding is ordered: success clears, failure keeps the current lease,
# and a previously released opaque identifier can become current again.
write_crabbox_meta lease-task lease-profile
run_cli lease-task run --lease lease-a -- printf lease-a-first
expect_code 0 "$RUN_STATUS" 'first explicit lease run succeeds'
run_cli lease-task release
expect_code 0 "$RUN_STATUS" 'successful lease release succeeds'
journal_has lease-task '.[2].event == "release" and .[2].lease == "lease-a" and .[2].exit_code == 0'
run_cli lease-task inspect
[ "$RUN_STATUS" -ne 0 ] || fail 'successful lease release did not clear current lease'
assert_contains "$RUN_STDERR" 'no unreleased Crabbox lease' 'cleared lease cannot be inspected'
run_cli lease-task run --lease lease-b -- printf lease-b
expect_code 0 "$RUN_STATUS" 'second explicit lease run succeeds'
export CRABBOX_STOP_STATUS=19
run_cli lease-task release
expect_code 19 "$RUN_STATUS" 'failed lease release preserves provider failure'
journal_has lease-task '.[5].event == "release" and .[5].lease == "lease-b" and .[5].exit_code == 19'
: > "$CRABBOX_LOG"
export CRABBOX_NONOBJECT=0
run_cli lease-task inspect
expect_code 0 "$RUN_STATUS" 'current lease can be inspected after failed release'
assert_contains "$RUN_STDOUT" '"cost":12.5' 'provider cost survives validated inspect'
assert_present "$STATE/lease-task.execution-provider.json" 'provider snapshot is stored'
jq -e '.id == "lease-b" and .cost == 12.5 and .expires_at == "2099-01-02T03:04:05Z"' "$STATE/lease-task.execution-provider.json" >/dev/null \
  || fail 'provider snapshot lost validated cost or expiry fields'
assert_grep 'argv: status --id lease-b --json' "$CRABBOX_LOG" 'inspect uses exactly the current task lease'
export CRABBOX_STOP_STATUS=0
run_cli lease-task release
expect_code 0 "$RUN_STATUS" 'current lease can be released after retry'
run_cli lease-task inspect
[ "$RUN_STATUS" -ne 0 ] || fail 'successful retry release did not clear current lease'
run_cli lease-task run --lease lease-a -- printf lease-a-reused
expect_code 0 "$RUN_STATUS" 'reused released lease becomes current again'
: > "$CRABBOX_LOG"
run_cli lease-task inspect
expect_code 0 "$RUN_STATUS" 'reused current lease can be inspected'
assert_grep 'argv: status --id lease-a --json' "$CRABBOX_LOG" 'reused identifier is the current lease again'

# A second task cannot use another task's current lease, and release targets
# exactly the current lease recorded by the first task.
write_crabbox_meta other-task other-profile
: > "$CRABBOX_LOG"
run_cli other-task inspect
[ "$RUN_STATUS" -ne 0 ] || fail 'second task inspected another task lease'
run_cli other-task release
[ "$RUN_STATUS" -ne 0 ] || fail 'second task released another task lease'
[ ! -s "$CRABBOX_LOG" ] || fail 'second task called Crabbox without a task-bound lease'
run_cli lease-task release
expect_code 0 "$RUN_STATUS" 'exact current lease release succeeds'
assert_grep 'argv: stop lease-a' "$CRABBOX_LOG" 'release stops exactly the current lease'

# Provider output must be a JSON object; malformed provider data is refused and
# cannot be committed as a task snapshot.
write_crabbox_meta provider-json provider-profile
run_cli provider-json run --lease lease-json -- printf provider-json
expect_code 0 "$RUN_STATUS" 'provider JSON task run succeeds'
export CRABBOX_NONOBJECT=1
run_cli provider-json inspect
[ "$RUN_STATUS" -ne 0 ] || fail 'non-object provider JSON was accepted'
assert_contains "$RUN_STDERR" 'did not return a JSON object' 'non-object provider JSON refusal is explicit'
assert_absent "$STATE/provider-json.execution-provider.json" 'non-object provider JSON was not stored'
export CRABBOX_NONOBJECT=0
run_cli provider-json release
expect_code 0 "$RUN_STATUS" 'provider JSON task lease releases'

write_crabbox_meta provider-multidoc provider-multidoc-profile
run_cli provider-multidoc run --lease lease-multidoc -- printf provider-multidoc
expect_code 0 "$RUN_STATUS" 'multi-document provider task run succeeds'
export CRABBOX_MULTIDOC=1
run_cli provider-multidoc inspect
[ "$RUN_STATUS" -ne 0 ] || fail 'multi-document provider JSON was accepted'
assert_contains "$RUN_STDERR" 'did not return a JSON object' 'multi-document provider JSON refusal is explicit'
assert_absent "$STATE/provider-multidoc.execution-provider.json" 'multi-document provider JSON was not stored'
export CRABBOX_MULTIDOC=0
run_cli provider-multidoc release
expect_code 0 "$RUN_STATUS" 'multi-document provider task lease releases'

# Canonical metadata and private artifacts reject malformed and symlinked state.
write_local_meta bad-meta
printf 'worktree=%s\nworktree=%s\n' "$WORKTREE" "$WORKTREE" > "$STATE/bad-meta.meta"
run_cli bad-meta check
[ "$RUN_STATUS" -ne 0 ] || fail 'duplicate metadata was accepted'
assert_contains "$RUN_STDERR" 'duplicate worktree' 'malformed metadata refusal is explicit'
write_local_meta bad-meta-link-target
ln -s "$STATE/bad-meta-link-target.meta" "$STATE/bad-meta-link.meta"
run_cli bad-meta-link check
[ "$RUN_STATUS" -ne 0 ] || fail 'symlinked metadata was accepted'
assert_contains "$RUN_STDERR" 'metadata is unavailable' 'symlinked metadata refusal is explicit'
fm_write_meta "$STATE/unknown-executor.meta" \
  "worktree=$WORKTREE" \
  'executor=unknown' \
  'executor_profile=unknown-profile'
run_cli unknown-executor check
[ "$RUN_STATUS" -ne 0 ] || fail 'unknown task executor selected a fallback'
assert_contains "$RUN_STDERR" "unsupported executor 'unknown'" 'unknown task executor refusal is explicit'


write_local_meta bad-journal
printf '{not-json}\n' > "$STATE/bad-journal.execution"
chmod 600 "$STATE/bad-journal.execution"
run_cli bad-journal run -- printf should-refuse
[ "$RUN_STATUS" -ne 0 ] || fail 'malformed journal was accepted'
assert_contains "$RUN_STDERR" 'journal is malformed' 'malformed journal refusal is explicit'
write_local_meta symlink-journal
printf '%s\n' '{"schema":"fm-execution-record.v1"}' > "$TMP_ROOT/journal-target"
chmod 600 "$TMP_ROOT/journal-target"
ln -s "$TMP_ROOT/journal-target" "$STATE/symlink-journal.execution"
run_cli symlink-journal run -- printf should-refuse
[ "$RUN_STATUS" -ne 0 ] || fail 'symlinked journal was accepted'
assert_contains "$RUN_STDERR" 'journal is unsafe' 'symlinked journal refusal is explicit'

write_crabbox_meta bad-snapshot bad-snapshot-profile
printf '{not-json}\n' > "$STATE/bad-snapshot.execution-provider.json"
chmod 644 "$STATE/bad-snapshot.execution-provider.json"
run_cli bad-snapshot inspect
[ "$RUN_STATUS" -ne 0 ] || fail 'malformed provider snapshot was accepted'
assert_contains "$RUN_STDERR" 'provider snapshot is unsafe' 'malformed provider snapshot refusal is explicit'
write_crabbox_meta symlink-snapshot symlink-snapshot-profile
printf '%s\n' '{}' > "$TMP_ROOT/snapshot-target"
chmod 600 "$TMP_ROOT/snapshot-target"
ln -s "$TMP_ROOT/snapshot-target" "$STATE/symlink-snapshot.execution-provider.json"
run_cli symlink-snapshot inspect
[ "$RUN_STATUS" -ne 0 ] || fail 'symlinked provider snapshot was accepted'
assert_contains "$RUN_STDERR" 'provider snapshot is unsafe' 'symlinked provider snapshot refusal is explicit'

pass 'command execution adapters and task-scoped Crabbox behavior'
