#!/usr/bin/env bash
# tests/fm-remote-ssh.test.sh - fake-ssh unit tests for bin/fm-remote-ssh.sh,
# PR 1 of the phase-4 remote-run series (data/phase4-sshpane-design-s1).
# Mirrors tests/fm-backend-herdr.test.sh's fakebin/command-log convention with
# a fake `ssh` that logs every invocation (one line, unit-separated args) and
# then either EXECUTES the remote command locally with real git (mode "exec",
# so the actual remote script logic is exercised against real repositories),
# fails like an unreachable host (mode "fail"), replays a canned response
# (mode "canned", for protocol/refusal parsing), or blocks like a hung remote
# command (mode "hang", for the wall-clock deadline). No real ssh connection
# is ever made: the fake shadows ssh on PATH for every case.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RS="$ROOT/bin/fm-remote-ssh.sh"
TMP_ROOT=$(fm_test_tmproot fm-remote-ssh-tests)
# Registry paths are validated strictly (no doubled slash, no dot components),
# and a trailing-slash TMPDIR would embed "//" into fixture paths - normalize
# the case root to its physical path once (mkdir -p first, matching the other
# suites' pattern of recreating the root before use).
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

# One shared fake-ssh; per-test log files via FM_SSH_LOG. In exec mode the
# remote command (ssh's final argument, "bash -lc <quoted-script>") runs
# locally under a scratch HOME so a login shell sources no user profile noise.
make_ssh_fakebin() {  # <dir> -> echoes fakebin dir
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/ssh" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_SSH_LOG:?}"
{
  printf 'ssh'
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
mode="${FM_FAKE_SSH_MODE:-exec}"
case "$mode" in
  exec)
    cmd=
    for a in "$@"; do cmd=$a; done
    HOME="${FM_FAKE_SSH_HOME:?}" exec bash -c "$cmd"
    ;;
  fail)
    exit 255
    ;;
  canned)
    [ -n "${FM_FAKE_SSH_CANNED:-}" ] && cat "$FM_FAKE_SSH_CANNED"
    exit "${FM_FAKE_SSH_EXIT:-0}"
    ;;
  hang)
    exec sleep 30
    ;;
esac
exit 0
SH
  chmod +x "$fb/ssh"
  printf '%s\n' "$fb"
}

FB=$(make_ssh_fakebin "$TMP_ROOT")
SSH_HOME="$TMP_ROOT/ssh-home"
mkdir -p "$SSH_HOME"

# case_env <name>: create an isolated case dir with a config dir, a "remote"
# project repo normalized to branch main, a task root, and an empty ssh log.
# Echoes the case dir; the registry is written separately per test.
case_env() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/config" "$dir/taskroot"
  fm_git_init_commit "$dir/remote-proj"
  git -C "$dir/remote-proj" branch -M main
  : > "$dir/ssh.log"
  printf '%s\n' "$dir"
}

# write_host <dir> [extra registry lines...]: write the default single-host
# registry (host vps1, non-client, no login shell) plus any extra lines.
write_host() {
  local dir=$1
  shift
  {
    printf 'vps1 alias=fmvps class=non-client login-shell=no task-root=%s handoff=origin\n' "$dir/taskroot"
    [ "$#" -gt 0 ] && printf '%s\n' "$@"
  } > "$dir/config/remote-hosts"
}

# run_rs <dir> <mode> <args...>: run fm-remote-ssh.sh with the fake ssh and
# this case's config; captures OUT and STATUS. Canned-mode tests preset
# CANNED (a response file) and optionally CANNED_EXIT before calling; the
# deadline test presets DEADLINE (seconds, empty means the script default).
OUT=
STATUS=0
run_rs() {
  local dir=$1 mode=$2
  shift 2
  OUT=$(PATH="$FB:$PATH" \
    FM_CONFIG_OVERRIDE="$dir/config" \
    FM_SSH_LOG="$dir/ssh.log" \
    FM_FAKE_SSH_MODE="$mode" \
    FM_FAKE_SSH_HOME="$SSH_HOME" \
    FM_FAKE_SSH_CANNED="${CANNED:-}" \
    FM_FAKE_SSH_EXIT="${CANNED_EXIT:-0}" \
    FM_REMOTE_SSH_DEADLINE="${DEADLINE:-}" \
    "$RS" "$@" 2>&1)
  STATUS=$?
}

# --- registry validation (all refuse BEFORE any ssh call) --------------------

test_registry_missing_file_refuses() {
  local dir
  dir=$(case_env reg-missing)
  run_rs "$dir" exec resolve vps1
  [ "$STATUS" -ne 0 ] || fail "resolve should refuse when config/remote-hosts is absent"
  assert_contains "$OUT" "no remote host registry" "missing registry not reported"
  [ ! -s "$dir/ssh.log" ] || fail "no ssh call may happen without a registry"
  pass "registry: an absent config/remote-hosts refuses with no ssh call"
}

test_registry_unknown_host_refuses() {
  local dir
  dir=$(case_env reg-unknown)
  write_host "$dir"
  run_rs "$dir" exec resolve nosuch
  [ "$STATUS" -ne 0 ] || fail "resolve should refuse an unregistered host id"
  assert_contains "$OUT" "unknown remote host" "unknown host not reported"
  [ ! -s "$dir/ssh.log" ] || fail "no ssh call may happen for an unknown host"
  pass "registry: an unregistered host id refuses with no ssh call"
}

test_registry_missing_field_refuses() {
  local dir
  dir=$(case_env reg-missing-field)
  printf 'vps1 alias=fmvps class=non-client login-shell=no handoff=origin\n' \
    > "$dir/config/remote-hosts"
  run_rs "$dir" exec resolve vps1
  [ "$STATUS" -ne 0 ] || fail "a host line without task-root must refuse"
  assert_contains "$OUT" "missing required field" "missing field not reported"
  pass "registry: a line missing a required field refuses the registry"
}

test_registry_duplicate_host_refuses() {
  local dir
  dir=$(case_env reg-dup)
  write_host "$dir" \
    "vps1 alias=other class=non-client login-shell=no task-root=/srv/tasks handoff=origin"
  run_rs "$dir" exec resolve vps1
  [ "$STATUS" -ne 0 ] || fail "a duplicate host id must refuse"
  assert_contains "$OUT" "duplicate host id" "duplicate host id not reported"
  pass "registry: a duplicate host id refuses the registry"
}

test_registry_bad_class_refuses() {
  local dir
  dir=$(case_env reg-bad-class)
  printf 'vps1 alias=fmvps class=friendly login-shell=no task-root=/srv/tasks handoff=origin\n' \
    > "$dir/config/remote-hosts"
  run_rs "$dir" exec resolve vps1
  [ "$STATUS" -ne 0 ] || fail "class must be client or non-client"
  assert_contains "$OUT" "class must be client or non-client" "bad class not reported"
  pass "registry: a class outside client|non-client refuses"
}

test_registry_relative_task_root_refuses() {
  local dir
  dir=$(case_env reg-rel-root)
  printf 'vps1 alias=fmvps class=non-client login-shell=no task-root=srv/tasks handoff=origin\n' \
    > "$dir/config/remote-hosts"
  run_rs "$dir" exec resolve vps1
  [ "$STATUS" -ne 0 ] || fail "a relative task-root must refuse"
  assert_contains "$OUT" "task-root must be a clean absolute path" "relative task-root not reported"
  pass "registry: a relative task-root refuses"
}

test_registry_dotdot_task_root_refuses() {
  local dir
  dir=$(case_env reg-dotdot-root)
  printf 'vps1 alias=fmvps class=non-client login-shell=no task-root=/srv/../etc handoff=origin\n' \
    > "$dir/config/remote-hosts"
  run_rs "$dir" exec resolve vps1
  [ "$STATUS" -ne 0 ] || fail "a task-root with a .. component must refuse"
  pass "registry: a task-root containing a dot-dot component refuses"
}

test_registry_dash_alias_refuses() {
  local dir
  dir=$(case_env reg-dash-alias)
  printf 'vps1 alias=-oProxyCommand=evil class=non-client login-shell=no task-root=/srv/tasks handoff=origin\n' \
    > "$dir/config/remote-hosts"
  run_rs "$dir" exec resolve vps1
  [ "$STATUS" -ne 0 ] || fail "an alias with a leading dash (ssh option injection) must refuse"
  assert_contains "$OUT" "invalid alias value" "dash alias not reported"
  pass "registry: an alias with a leading dash (option injection) refuses"
}

test_registry_unknown_key_refuses() {
  local dir
  dir=$(case_env reg-unknown-key)
  printf 'vps1 alias=fmvps class=non-client login-shell=no task-root=/srv/tasks handoff=origin sudo=yes\n' \
    > "$dir/config/remote-hosts"
  run_rs "$dir" exec resolve vps1
  [ "$STATUS" -ne 0 ] || fail "an unknown registry key must refuse"
  assert_contains "$OUT" "unknown key" "unknown key not reported"
  pass "registry: an unknown key on any line refuses"
}

test_resolve_prints_validated_entry() {
  local dir
  dir=$(case_env reg-resolve-ok)
  write_host "$dir"
  run_rs "$dir" exec resolve vps1
  expect_code 0 "$STATUS" "resolve of a valid host should succeed"
  assert_contains "$OUT" "host=vps1" "resolve did not print the host id"
  assert_contains "$OUT" "alias=fmvps" "resolve did not print the alias"
  assert_contains "$OUT" "class=non-client" "resolve did not print the class"
  assert_contains "$OUT" "login_shell=no" "resolve did not print the login-shell mode"
  assert_contains "$OUT" "task_root=$dir/taskroot" "resolve did not print the task root"
  assert_contains "$OUT" "handoff=origin" "resolve did not print the handoff remotes"
  [ ! -s "$dir/ssh.log" ] || fail "resolve is local-only and must not call ssh"
  pass "resolve: prints the validated registry entry without any ssh call"
}

# --- injection attempts (refused locally, no ssh spawn, no side effect) ------

test_injection_arguments_refused_before_ssh() {
  local dir marker
  dir=$(case_env inject-args)
  write_host "$dir"
  marker="$dir/pwned"
  local bad_proj bad_id bad_ref
  # The single-quoted $(...) payloads below are deliberate literals: the test
  # proves they are refused, never expanded.
  # shellcheck disable=SC2016
  for bad_proj in "/tmp/x;touch $marker" '/tmp/$(touch pwned)' '/tmp/a b' '/tmp/../etc' '//tmp/x'; do
    run_rs "$dir" exec worktree-create vps1 "$bad_proj" task1 main
    [ "$STATUS" -ne 0 ] || fail "project '$bad_proj' must be refused"
  done
  # shellcheck disable=SC2016
  for bad_id in 'a;b' '../up' 'a b' '.hidden' 'a$(touch pwned)' 'a/b'; do
    run_rs "$dir" exec worktree-create vps1 "$dir/remote-proj" "$bad_id" main
    [ "$STATUS" -ne 0 ] || fail "task id '$bad_id' must be refused"
  done
  # shellcheck disable=SC2016
  for bad_ref in '-D' 'a;b' 'a..b' 'refs/heads/x y' '$(reboot)'; do
    run_rs "$dir" exec worktree-create vps1 "$dir/remote-proj" task1 "$bad_ref"
    [ "$STATUS" -ne 0 ] || fail "base ref '$bad_ref' must be refused"
  done
  [ ! -s "$dir/ssh.log" ] || fail "an injection attempt must be refused BEFORE any ssh call"
  assert_absent "$marker" "an injection payload executed (marker file created)"
  pass "injection: hostile project/task-id/base-ref values refuse before any ssh call"
}

# --- ssh invocation shape ----------------------------------------------------

test_ssh_invocation_shape_and_login_shell() {
  local dir log
  dir=$(case_env ssh-shape)
  write_host "$dir" \
    "ccag alias=ccagw class=client login-shell=yes task-root=/srv/tasks handoff=origin"
  CANNED="$dir/resp"
  printf 'fm-remote-v1 preflight uid=501 project=%s taskroot=dir\n' "$dir/remote-proj" > "$CANNED"
  run_rs "$dir" canned preflight vps1 "$dir/remote-proj"
  expect_code 0 "$STATUS" "canned preflight should succeed"
  log=$(cat "$dir/ssh.log")
  assert_contains "$log" $'\x1f''-o'$'\x1f''BatchMode=yes' "ssh call missing BatchMode=yes (must never prompt)"
  assert_contains "$log" "ConnectTimeout=" "ssh call missing a bounded ConnectTimeout"
  assert_contains "$log" $'\x1f''--'$'\x1f''fmvps' "ssh call missing '--' before the alias (option-injection guard)"
  assert_contains "$log" $'\x1f''bash -c ' "login-shell=no host must run through bash -c"
  : > "$dir/ssh.log"
  printf 'fm-remote-v1 preflight uid=501 project=/srv/proj taskroot=dir\n' > "$CANNED"
  run_rs "$dir" canned preflight ccag /srv/proj
  expect_code 0 "$STATUS" "canned preflight on the login-shell host should succeed"
  log=$(cat "$dir/ssh.log")
  assert_contains "$log" $'\x1f''--'$'\x1f''ccagw' "second host's alias not used"
  assert_contains "$log" $'\x1f''bash -lc ' "login-shell=yes host must run through bash -lc"
  CANNED=
  pass "transport: BatchMode, bounded timeout, '--' alias guard, and login-shell selection"
}

# --- transport and protocol refusals ----------------------------------------

test_unreachable_host_refuses() {
  local dir
  dir=$(case_env ssh-fail)
  write_host "$dir"
  run_rs "$dir" fail preflight vps1 "$dir/remote-proj"
  [ "$STATUS" -ne 0 ] || fail "an unreachable host must refuse"
  assert_contains "$OUT" "ssh exit 255" "transport failure not reported"
  pass "transport: an unreachable host (ssh exit 255) refuses"
}

test_deadline_bounds_hung_remote() {
  local dir
  dir=$(case_env ssh-hang)
  write_host "$dir"
  DEADLINE=1
  run_rs "$dir" hang preflight vps1 "$dir/remote-proj"
  DEADLINE=
  [ "$STATUS" -ne 0 ] || fail "a hung remote command must refuse at the deadline"
  assert_contains "$OUT" "wall-clock deadline" "deadline expiry not reported"
  pass "transport: a hung remote command is killed at the wall-clock deadline"
}

test_garbage_response_refuses() {
  local dir
  dir=$(case_env resp-garbage)
  write_host "$dir"
  CANNED="$dir/resp"
  printf 'Welcome to the server!\ntotally not a protocol line\n' > "$CANNED"
  run_rs "$dir" canned preflight vps1 "$dir/remote-proj"
  [ "$STATUS" -ne 0 ] || fail "a response without a protocol line must refuse"
  assert_contains "$OUT" "unexpected remote response" "garbage response not refused"
  CANNED=
  pass "protocol: output with no fm-remote-v1 line refuses"
}

test_multiple_protocol_lines_refuse() {
  local dir
  dir=$(case_env resp-multi)
  write_host "$dir"
  CANNED="$dir/resp"
  printf 'fm-remote-v1 preflight uid=501 project=/p taskroot=dir\nfm-remote-v1 preflight uid=0 project=/p taskroot=dir\n' > "$CANNED"
  run_rs "$dir" canned preflight vps1 "$dir/remote-proj"
  [ "$STATUS" -ne 0 ] || fail "two protocol lines must refuse"
  assert_contains "$OUT" "multiple protocol lines" "duplicate protocol line not refused"
  CANNED=
  pass "protocol: more than one fm-remote-v1 line refuses"
}

test_wrong_verb_refuses() {
  local dir
  dir=$(case_env resp-verb)
  write_host "$dir"
  CANNED="$dir/resp"
  printf 'fm-remote-v1 worktree-create path=/x branch=fm/t head=0 base_oid=0\n' > "$CANNED"
  run_rs "$dir" canned preflight vps1 "$dir/remote-proj"
  [ "$STATUS" -ne 0 ] || fail "a mismatched verb must refuse"
  assert_contains "$OUT" "verb mismatch" "verb mismatch not refused"
  CANNED=
  pass "protocol: a response with the wrong verb refuses"
}

test_unknown_field_refuses() {
  local dir
  dir=$(case_env resp-field)
  write_host "$dir"
  CANNED="$dir/resp"
  printf 'fm-remote-v1 preflight uid=501 project=/p taskroot=dir evil=1\n' > "$CANNED"
  run_rs "$dir" canned preflight vps1 "$dir/remote-proj"
  [ "$STATUS" -ne 0 ] || fail "an unknown response field must refuse"
  assert_contains "$OUT" "unknown field" "unknown field not refused"
  CANNED=
  pass "protocol: an unallowlisted response field refuses"
}

test_remote_refuse_reason_is_relayed() {
  local dir
  dir=$(case_env resp-refuse)
  write_host "$dir"
  CANNED="$dir/resp"
  printf 'fm-remote-v1 refuse reason=not-a-repo\n' > "$CANNED"
  run_rs "$dir" canned preflight vps1 "$dir/remote-proj"
  [ "$STATUS" -ne 0 ] || fail "a remote refuse must exit nonzero"
  assert_contains "$OUT" "remote refused: not-a-repo" "remote refusal code not relayed"
  CANNED=
  pass "protocol: a remote refuse reason is relayed as a local refusal"
}

test_root_uid_refuses() {
  local dir
  dir=$(case_env resp-root)
  write_host "$dir"
  CANNED="$dir/resp"
  printf 'fm-remote-v1 preflight uid=0 project=/p taskroot=dir\n' > "$CANNED"
  run_rs "$dir" canned preflight vps1 "$dir/remote-proj"
  [ "$STATUS" -ne 0 ] || fail "a root remote user must refuse"
  assert_contains "$OUT" "is root" "root remote user not refused"
  CANNED=
  pass "preflight: a remote root user refuses (non-root harness constraint)"
}

# --- preflight against real local git (exec mode) ----------------------------

test_preflight_happy_path() {
  local dir
  dir=$(case_env pre-ok)
  write_host "$dir"
  run_rs "$dir" exec preflight vps1 "$dir/remote-proj"
  expect_code 0 "$STATUS" "preflight against a real repo should succeed: $OUT"
  assert_contains "$OUT" "host=vps1" "preflight did not print the host"
  assert_contains "$OUT" "class=non-client" "preflight did not print the class"
  assert_contains "$OUT" "taskroot=dir" "preflight did not report the existing task root"
  pass "preflight: a valid non-root host with a real repo passes"
}

test_preflight_not_a_repo_refuses() {
  local dir
  dir=$(case_env pre-norepo)
  write_host "$dir"
  mkdir -p "$dir/plain"
  run_rs "$dir" exec preflight vps1 "$dir/plain"
  [ "$STATUS" -ne 0 ] || fail "a non-repo project must refuse"
  assert_contains "$OUT" "remote refused: not-a-repo" "non-repo not refused"
  pass "preflight: a project directory that is not a git repo refuses"
}

test_preflight_non_toplevel_refuses() {
  local dir
  dir=$(case_env pre-subdir)
  write_host "$dir"
  mkdir -p "$dir/remote-proj/subdir"
  run_rs "$dir" exec preflight vps1 "$dir/remote-proj/subdir"
  [ "$STATUS" -ne 0 ] || fail "a repo subdirectory must refuse"
  assert_contains "$OUT" "remote refused: project-not-toplevel" "non-toplevel project not refused"
  pass "preflight: a repo subdirectory given as the project refuses"
}

# --- worktree create/inspect/remove happy paths (exec mode, real git) --------

test_create_happy_path() {
  local dir dest expected_head
  dir=$(case_env wt-create)
  write_host "$dir"
  run_rs "$dir" exec worktree-create vps1 "$dir/remote-proj" task1 main
  expect_code 0 "$STATUS" "worktree-create should succeed: $OUT"
  expected_head=$(git -C "$dir/remote-proj" rev-parse main)
  assert_contains "$OUT" "branch=fm/task1" "create did not report the task branch"
  assert_contains "$OUT" "head=$expected_head" "create did not report the base head oid"
  dest="$dir/taskroot/worktrees/remote-proj/task1"
  [ -d "$dest" ] || fail "the worktree was not created at the deterministic layout path"
  [ "$(git -C "$dest" rev-parse --abbrev-ref HEAD)" = "fm/task1" ] \
    || fail "the created worktree is not on fm/task1"
  git -C "$dir/remote-proj" worktree list --porcelain | grep -q "task1" \
    || fail "the worktree is not registered by the project"
  pass "worktree-create: creates a registered worktree on fm/<id> at the pinned base"
}

test_create_existing_path_refuses() {
  local dir
  dir=$(case_env wt-create-dup)
  write_host "$dir"
  run_rs "$dir" exec worktree-create vps1 "$dir/remote-proj" task1 main
  expect_code 0 "$STATUS" "first create should succeed"
  run_rs "$dir" exec worktree-create vps1 "$dir/remote-proj" task1 main
  [ "$STATUS" -ne 0 ] || fail "a second create over an existing path must refuse"
  assert_contains "$OUT" "remote refused: path-exists" "existing path not refused"
  pass "worktree-create: an existing task path refuses instead of being reused"
}

test_create_existing_branch_refuses() {
  local dir
  dir=$(case_env wt-create-branch)
  write_host "$dir"
  git -C "$dir/remote-proj" branch fm/task1 main
  run_rs "$dir" exec worktree-create vps1 "$dir/remote-proj" task1 main
  [ "$STATUS" -ne 0 ] || fail "a preexisting fm/<id> branch must refuse"
  assert_contains "$OUT" "remote refused: branch-exists" "existing branch not refused"
  pass "worktree-create: a preexisting task branch refuses (never reused silently)"
}

test_create_unknown_base_refuses() {
  local dir
  dir=$(case_env wt-create-base)
  write_host "$dir"
  run_rs "$dir" exec worktree-create vps1 "$dir/remote-proj" task1 nosuchref
  [ "$STATUS" -ne 0 ] || fail "an unknown base ref must refuse"
  assert_contains "$OUT" "remote refused: base-ref-unknown" "unknown base ref not refused"
  pass "worktree-create: an unknown base ref refuses"
}

test_inspect_absent_and_worktree_states() {
  local dir dest
  dir=$(case_env wt-inspect)
  write_host "$dir"
  run_rs "$dir" exec worktree-inspect vps1 "$dir/remote-proj" task1
  expect_code 0 "$STATUS" "inspect of an absent path should succeed with state=absent: $OUT"
  assert_contains "$OUT" "state=absent" "absent worktree not reported"
  run_rs "$dir" exec worktree-create vps1 "$dir/remote-proj" task1 main
  expect_code 0 "$STATUS" "create should succeed"
  run_rs "$dir" exec worktree-inspect vps1 "$dir/remote-proj" task1
  expect_code 0 "$STATUS" "inspect of a clean worktree should succeed: $OUT"
  assert_contains "$OUT" "state=worktree" "worktree state not reported"
  assert_contains "$OUT" "branch=fm/task1" "inspect did not report the branch"
  assert_contains "$OUT" "clean=yes" "a clean worktree must report clean=yes"
  dest="$dir/taskroot/worktrees/remote-proj/task1"
  touch "$dest/scratch.txt"
  run_rs "$dir" exec worktree-inspect vps1 "$dir/remote-proj" task1
  expect_code 0 "$STATUS" "inspect of a dirty worktree still succeeds (dirty is a fact)"
  assert_contains "$OUT" "clean=no" "a dirty worktree must report clean=no"
  assert_not_contains "$OUT" "scratch.txt" "inspect leaked a filename; clean is a boolean only"
  pass "worktree-inspect: reports absent, clean, and dirty as facts without filenames"
}

test_inspect_branch_mismatch_refuses() {
  local dir dest
  dir=$(case_env wt-inspect-branch)
  write_host "$dir"
  dest="$dir/taskroot/worktrees/remote-proj/task1"
  mkdir -p "$(dirname "$dest")"
  git -C "$dir/remote-proj" worktree add --quiet -b other-branch "$dest" main
  run_rs "$dir" exec worktree-inspect vps1 "$dir/remote-proj" task1
  [ "$STATUS" -ne 0 ] || fail "a worktree on a foreign branch must refuse identity"
  assert_contains "$OUT" "not the task branch" "branch mismatch not refused"
  pass "worktree-inspect: a worktree on a non-task branch refuses identity"
}

test_remove_happy_path_keeps_branch() {
  local dir dest log
  dir=$(case_env wt-remove)
  write_host "$dir"
  run_rs "$dir" exec worktree-create vps1 "$dir/remote-proj" task1 main
  expect_code 0 "$STATUS" "create should succeed"
  dest="$dir/taskroot/worktrees/remote-proj/task1"
  run_rs "$dir" exec worktree-remove vps1 "$dir/remote-proj" task1
  expect_code 0 "$STATUS" "remove of a clean registered worktree should succeed: $OUT"
  assert_absent "$dest" "the worktree directory should be gone after remove"
  git -C "$dir/remote-proj" rev-parse --verify --quiet refs/heads/fm/task1 >/dev/null \
    || fail "remove must NOT delete the fm/<id> branch (reachability proof is teardown's job)"
  log=$(cat "$dir/ssh.log")
  assert_not_contains "$log" "rm -rf" "the composed remote commands must never contain rm -rf"
  assert_not_contains "$log" "--force" "the composed remote commands must never contain --force"
  pass "worktree-remove: removes the clean worktree without --force and keeps the branch"
}

test_remove_dirty_refuses() {
  local dir dest
  dir=$(case_env wt-remove-dirty)
  write_host "$dir"
  run_rs "$dir" exec worktree-create vps1 "$dir/remote-proj" task1 main
  expect_code 0 "$STATUS" "create should succeed"
  dest="$dir/taskroot/worktrees/remote-proj/task1"
  touch "$dest/unlanded.txt"
  run_rs "$dir" exec worktree-remove vps1 "$dir/remote-proj" task1
  [ "$STATUS" -ne 0 ] || fail "a dirty worktree must refuse removal"
  assert_contains "$OUT" "remote refused: dirty" "dirty refusal not reported"
  assert_present "$dest/unlanded.txt" "the dirty worktree must be left untouched"
  pass "worktree-remove: a dirty worktree refuses and is left untouched"
}

test_remove_unregistered_refuses() {
  local dir dest
  dir=$(case_env wt-remove-unreg)
  write_host "$dir"
  dest="$dir/taskroot/worktrees/remote-proj/task1"
  fm_git_init_commit "$dest"
  run_rs "$dir" exec worktree-remove vps1 "$dir/remote-proj" task1
  [ "$STATUS" -ne 0 ] || fail "an unregistered repo at the task path must refuse removal"
  assert_contains "$OUT" "remote refused: unregistered" "unregistered refusal not reported"
  assert_present "$dest/README.md" "the unregistered directory must be left untouched"
  pass "worktree-remove: an unregistered directory at the task path refuses untouched"
}

test_remove_out_of_root_refuses() {
  local dir dest outside
  dir=$(case_env wt-remove-outroot)
  write_host "$dir"
  outside="$dir/elsewhere/task1"
  mkdir -p "$dir/elsewhere"
  git -C "$dir/remote-proj" worktree add --quiet -b fm/task1 "$outside" main
  dest="$dir/taskroot/worktrees/remote-proj/task1"
  mkdir -p "$(dirname "$dest")"
  ln -s "$outside" "$dest"
  run_rs "$dir" exec worktree-remove vps1 "$dir/remote-proj" task1
  [ "$STATUS" -ne 0 ] || fail "a task path resolving outside the task root must refuse"
  assert_contains "$OUT" "remote refused: out-of-root" "out-of-root refusal not reported"
  assert_present "$outside/README.md" "the out-of-root target must be left untouched"
  pass "worktree-remove: a path resolving outside the registered task root refuses untouched"
}

test_remove_dest_equal_to_root_refuses() {
  local dir dest
  dir=$(case_env wt-remove-destroot)
  write_host "$dir"
  dest="$dir/taskroot/worktrees/remote-proj/task1"
  mkdir -p "$(dirname "$dest")"
  ln -s "$dir/taskroot" "$dest"
  run_rs "$dir" exec worktree-remove vps1 "$dir/remote-proj" task1
  [ "$STATUS" -ne 0 ] || fail "a task path resolving to the task root itself must refuse"
  assert_contains "$OUT" "remote refused: out-of-root" "root-equal task path not refused"
  assert_present "$dir/taskroot" "the task root must be left untouched"
  pass "worktree-remove: a path resolving to the task root itself refuses untouched"
}

test_remove_absent_refuses() {
  local dir
  dir=$(case_env wt-remove-absent)
  write_host "$dir"
  run_rs "$dir" exec worktree-remove vps1 "$dir/remote-proj" task1
  [ "$STATUS" -ne 0 ] || fail "removing an absent worktree must refuse"
  assert_contains "$OUT" "remote refused: path-not-dir" "absent path refusal not reported"
  pass "worktree-remove: an absent task path refuses"
}

# --- run --------------------------------------------------------------------

test_registry_missing_file_refuses
test_registry_unknown_host_refuses
test_registry_missing_field_refuses
test_registry_duplicate_host_refuses
test_registry_bad_class_refuses
test_registry_relative_task_root_refuses
test_registry_dotdot_task_root_refuses
test_registry_dash_alias_refuses
test_registry_unknown_key_refuses
test_resolve_prints_validated_entry
test_injection_arguments_refused_before_ssh
test_ssh_invocation_shape_and_login_shell
test_unreachable_host_refuses
test_deadline_bounds_hung_remote
test_garbage_response_refuses
test_multiple_protocol_lines_refuse
test_wrong_verb_refuses
test_unknown_field_refuses
test_remote_refuse_reason_is_relayed
test_root_uid_refuses
test_preflight_happy_path
test_preflight_not_a_repo_refuses
test_preflight_non_toplevel_refuses
test_create_happy_path
test_create_existing_path_refuses
test_create_existing_branch_refuses
test_create_unknown_base_refuses
test_inspect_absent_and_worktree_states
test_inspect_branch_mismatch_refuses
test_remove_happy_path_keeps_branch
test_remove_out_of_root_refuses
test_remove_dest_equal_to_root_refuses
test_remove_dirty_refuses
test_remove_unregistered_refuses
test_remove_absent_refuses

echo "all fm-remote-ssh tests passed"
