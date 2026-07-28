#!/usr/bin/env bash
# Behavior tests for fm-bootstrap.sh reporting and session-start clone refresh bounds.
#
# Bootstrap prints one block or line per actionable problem, optional verbose
# BOOTSTRAP_INFO fact, or completed bootstrap no-action fact and is silent when
# all is well. firstmate consumes the exact 'MISSING: treehouse (install: ...)',
# 'MISSING: tasks-axi (install: ...)', 'MISSING: quota-axi (install: ...)', and
# 'BOOTSTRAP_INFO: ...' lines, so those contracts are pinned verbatim. The cases
# are table-driven over the inputs that vary: whether `treehouse get --help`
# advertises --lease, which (if any) tasks-axi version is on PATH, whether
# tasks-axi update advertises --archive-body, whether its mv help advertises
# multi-ID moves, whether quota-axi is on PATH,
# whether the local backend config opts out of tasks-axi backlog mutations, and
# which no-mistakes version is on PATH.
# Dedicated fleet-sync cases pin the computed bootstrap timeout, explicit
# override, blank-env defaulting, partial-output relay, and pre-launch timeout
# scan.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-bootstrap-tests)
export FM_BACKEND_CMUX_BUNDLE_BIN="$TMP_ROOT/no-bundled-cmux"

# Hermetic runtime-backend detection. These cases pin the backend per-home via
# config/backend; the dev shell's ambient runtime markers ($TMUX inside tmux,
# HERDR_ENV inside herdr, CMUX_* inside a cmux terminal) must not leak into
# fm_backend_name and flip a default-backend case onto a non-tmux backend. Unset
# them once so the suite resolves the tmux reference backend unless a case says
# otherwise - the same hermeticity discipline as pinning PATH via BASE_PATH.
unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH \
  CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_SOCKET_PATH CMUX_TAB_ID CMUX_PANEL_ID 2>/dev/null || true

# A fake toolchain where every required tool is present and gh is authenticated.
# treehouse's `get --help` advertises --lease only when FM_FAKE_TREEHOUSE_LEASE_HELP=1.
make_fake_toolchain() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" tmux node gh-axi chrome-devtools-axi lavish-axi
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FAKE_TREEHOUSE_CALLS:-}" ] || printf '%s in %s\n' "$*" "$PWD" >> "$FM_FAKE_TREEHOUSE_CALLS"
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  if [ "${FM_FAKE_TREEHOUSE_LEASE_HELP:-}" = 1 ]; then
    printf '%s\n' 'Usage: treehouse get [--lease] [--lease-holder <holder>]'
  else
    printf '%s\n' 'Usage: treehouse get'
  fi
  exit 0
fi
if [ "${1:-}" = status ]; then
  if [ -n "${FM_FAKE_TREEHOUSE_STATUS_BY_DIR:-}" ] \
    && [ -f "$FM_FAKE_TREEHOUSE_STATUS_BY_DIR/$(basename "$PWD")" ]; then
    if grep -q FM_FAKE_TREEHOUSE_HANG "$FM_FAKE_TREEHOUSE_STATUS_BY_DIR/$(basename "$PWD")"; then
      sleep 120
      exit 0
    fi
    slow=$(sed -n 's/^FM_FAKE_TREEHOUSE_SLOW //p' "$FM_FAKE_TREEHOUSE_STATUS_BY_DIR/$(basename "$PWD")")
    [ -z "$slow" ] || sleep "$slow"
    grep -v '^FM_FAKE_TREEHOUSE_SLOW ' "$FM_FAKE_TREEHOUSE_STATUS_BY_DIR/$(basename "$PWD")" || true
  elif [ -n "${FM_FAKE_TREEHOUSE_STATUS_FILE:-}" ]; then
    cat "$FM_FAKE_TREEHOUSE_STATUS_FILE"
  fi
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' "${FM_FAKE_NO_MISTAKES_VERSION:-no-mistakes version v1.31.2 (fake) 2026-06-27T00:02:18Z}"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  add_tasks_axi "$fakebin" "0.1.1"
  add_quota_axi "$fakebin"
  printf '%s\n' "$fakebin"
}

add_quota_axi() {
  local fakebin=$1
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/quota-axi"
}

add_tasks_axi() {
  local fakebin=$1 version=$2 archive_body=${3:-yes} multi_id=${4:-yes} archive_line mv_usage
  archive_line=""
  [ "$archive_body" = yes ] && archive_line='  --archive-body'
  mv_usage='usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>'
  [ "$multi_id" = yes ] || mv_usage='usage: tasks-axi mv <id> --to <path-or-dir>'
  cat > "$fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then
  printf '%s\n' '$version'
  exit 0
fi
if [ "\${1:-}" = update ] && [ "\${2:-}" = --help ]; then
  printf '%s\n' 'usage: tasks-axi update <id> [flags]'
  printf '%s\n' '  --body-file <path>'
  [ -z '$archive_line' ] || printf '%s\n' '$archive_line'
  exit 0
fi
if [ "\${1:-}" = mv ] && [ "\${2:-}" = --help ]; then
  printf '%s\n' '$mv_usage'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
}

add_real_jq() {
  local fakebin=$1 real_jq
  real_jq=$(command -v jq 2>/dev/null) || fail "jq is required for dispatch profile validation tests"
  cat > "$fakebin/jq" <<SH
#!/usr/bin/env bash
exec '$real_jq' "\$@"
SH
  chmod +x "$fakebin/jq"
}

make_fake_fleet_sync_root() {
  local dir=$1 fake_root
  fake_root="$dir/fake-root"
  mkdir -p "$fake_root/bin"
  cat > "$fake_root/bin/fm-fleet-sync.sh" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FAKE_FLEET_SYNC_STARTED_MARKER:-}" ] || : > "$FM_FAKE_FLEET_SYNC_STARTED_MARKER"
printf '%s\n' 'alpha: synced'
printf '%s\n' 'beta: skipped: no origin remote'
exec perl -e 'sleep 300'
SH
  chmod +x "$fake_root/bin/fm-fleet-sync.sh"
  printf '%s\n' "$fake_root"
}

add_origin_backed_projects() {
  local home=$1 count=$2 i repo
  mkdir -p "$home/projects"
  i=1
  while [ "$i" -le "$count" ]; do
    repo=$(printf '%s/projects/repo-%02d' "$home" "$i")
    git init -q "$repo"
    git -C "$repo" remote add origin "file://$home/remotes/repo-$i.git"
    i=$((i + 1))
  done
}

add_no_origin_projects() {
  local home=$1 count=$2 i repo
  mkdir -p "$home/projects"
  i=1
  while [ "$i" -le "$count" ]; do
    repo=$(printf '%s/projects/local-%02d' "$home" "$i")
    git init -q "$repo"
    i=$((i + 1))
  done
}

run_bootstrap_timeout_case() {
  local home=$1 fake_root=$2 fakebin=$3 override started_marker git_record wait_for_marker
  override=__unset__
  started_marker=${5:-}
  git_record=${6:-}
  wait_for_marker=${7:-0}
  [ "$#" -lt 4 ] || override=$4
  (
    # shellcheck disable=SC2317,SC2329 # Exported and invoked by the bootstrap subprocess.
    sleep() {
      local inc=${1:-1}
      SECONDS=$((SECONDS + inc))
      # Advance fake time quickly, but yield on every tick so the background
      # fleet-sync process can deterministically write its partial output before
      # the simulated timeout kills it, even on a busy full-suite runner.
      command sleep 0.01
    }
    # shellcheck disable=SC2317,SC2329 # Exported and invoked by the bootstrap subprocess.
    git() {
      local tries
      if [ "${FM_FAKE_GIT_WAIT_FOR_FLEET_START:-}" = 1 ] && [ -n "${FM_FAKE_FLEET_SYNC_STARTED_MARKER:-}" ]; then
        tries=0
        while [ "$tries" -lt 5 ] && [ ! -e "$FM_FAKE_FLEET_SYNC_STARTED_MARKER" ]; do
          command sleep 0.01
          tries=$((tries + 1))
        done
      fi
      if [ -n "${FM_FAKE_GIT_SYNC_STARTED_RECORD:-}" ] && [ -n "${FM_FAKE_FLEET_SYNC_STARTED_MARKER:-}" ] && [ -e "$FM_FAKE_FLEET_SYNC_STARTED_MARKER" ]; then
        printf '%s\n' "$*" >> "$FM_FAKE_GIT_SYNC_STARTED_RECORD"
      fi
      command git "$@"
    }
    export -f sleep
    export -f git
    if [ "$override" = __unset__ ]; then
      PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$fake_root" \
        FM_FAKE_FLEET_SYNC_STARTED_MARKER="$started_marker" \
        FM_FAKE_GIT_SYNC_STARTED_RECORD="$git_record" \
        FM_FAKE_GIT_WAIT_FOR_FLEET_START="$wait_for_marker" \
        FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null
    else
      PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$fake_root" \
        FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT="$override" \
        FM_FAKE_FLEET_SYNC_STARTED_MARKER="$started_marker" \
        FM_FAKE_GIT_SYNC_STARTED_RECORD="$git_record" \
        FM_FAKE_GIT_WAIT_FOR_FLEET_START="$wait_for_marker" \
        FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null
    fi
  )
}

assert_timeout_report() {
  local out=$1 expected_timeout=$2 timing timeout elapsed
  timing=$(printf '%s\n' "$out" | sed -n 's/^FLEET_SYNC: fleet: skipped: bootstrap refresh timed out (timeout=\([0-9][0-9]*\)s elapsed=\([0-9][0-9]*\)s)$/\1 \2/p')
  [ -n "$timing" ] || fail "missing fleet-sync timeout report"
  timeout=${timing%% *}
  elapsed=${timing#* }
  [ "$timeout" -eq "$expected_timeout" ] || fail "expected timeout=${expected_timeout}s, got timeout=${timeout}s"
  [ "$elapsed" -ge "$timeout" ] || fail "expected elapsed >= timeout, got elapsed=${elapsed}s timeout=${timeout}s"
}

# Each row (fields are '^'-separated; the install URL contains a literal '|'):
#   <label>^<lease 1/0>^<tasks-axi version or ->^<quota 1/0>^<backend or ->^<mode>^<expect>^<notcontains>
#   mode=empty -> output must be empty (expect/notcontains ignored)
#   mode=exact -> output must equal <expect>
#   mode=grep  -> output must contain <expect> (fixed string); <notcontains> must not appear
test_bootstrap_reporting() {
  local label lease tasks quota backend mode expect notcontains case_dir fakebin out n archive_body multi_id
  n=0
  while IFS='^' read -r label lease tasks quota backend mode expect notcontains; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case_dir="$TMP_ROOT/case-$n"
    mkdir -p "$case_dir/home"
    if [ "$backend" != "-" ]; then
      mkdir -p "$case_dir/home/config"
      printf '%s\n' "$backend" > "$case_dir/home/config/backlog-backend"
    fi
    fakebin=$(make_fake_toolchain "$case_dir")
    if [ "$tasks" = "-" ]; then
      rm -f "$fakebin/tasks-axi"
    else
      archive_body=yes
      multi_id=yes
      case "$tasks" in
        *:noarchive)
          archive_body=no
          tasks=${tasks%:noarchive}
          ;;
      esac
      case "$tasks" in
        *:nomulti)
          multi_id=no
          tasks=${tasks%:nomulti}
          ;;
      esac
      add_tasks_axi "$fakebin" "$tasks" "$archive_body" "$multi_id"
    fi
    if [ "$quota" = "0" ]; then
      rm -f "$fakebin/quota-axi"
    fi
    # FM_ROOT_OVERRIDE points the worktree-tangle check at the non-git home dir so
    # it stays inert: this suite pins tool detection, not the tangle guard, and the
    # ambient checkout (CI runs on a feature branch) must not leak a TANGLE line in.
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
      FM_FAKE_TREEHOUSE_LEASE_HELP="$lease" "$ROOT/bin/fm-bootstrap.sh")
    case "$mode" in
      empty)
        [ -z "$out" ] || fail "$label: expected silence, got: $out" ;;
      exact)
        [ "$out" = "$expect" ] || fail "$label: expected '$expect', got: $out" ;;
      grep)
        printf '%s\n' "$out" | grep -Fx "$expect" >/dev/null || fail "$label: missing '$expect' (got: $out)"
        if [ -n "$notcontains" ]; then
          printf '%s\n' "$out" | grep -F "$notcontains" >/dev/null && fail "$label: unexpected '$notcontains' in: $out"
        fi
        ;;
    esac
  done <<'ROWS'
treehouse --lease support is accepted silently^1^0.1.1^1^manual^empty^^
treehouse without --lease reports an upgrade, gh auth is fine^0^0.1.1^1^-^grep^MISSING: treehouse (install: curl -fsSL https://kunchenguid.github.io/treehouse/install.sh | sh)^NEEDS_GH_AUTH
compatible tasks-axi is silent by default^1^0.1.1^1^-^empty^^
missing tasks-axi is required by default^1^-^1^-^exact^MISSING: tasks-axi (install: npm install -g tasks-axi)^
incompatible tasks-axi is required by default^1^0.1.0^1^-^exact^MISSING: tasks-axi (install: npm install -g tasks-axi)^
tasks-axi without archive-body is required by default^1^0.1.2:noarchive^1^-^exact^MISSING: tasks-axi (install: npm install -g tasks-axi)^
tasks-axi without multi-id mv is required by default^1^0.2.2:nomulti^1^-^exact^MISSING: tasks-axi (install: npm install -g tasks-axi)^
missing quota-axi is required by default^1^0.1.1^0^manual^exact^MISSING: quota-axi (install: npm install -g quota-axi)^
manual backlog backend still requires missing tasks-axi^1^-^1^manual^exact^MISSING: tasks-axi (install: npm install -g tasks-axi)^
manual backlog backend suppresses tasks-axi availability^1^0.1.1^1^manual^empty^^
ROWS
  pass "bootstrap reports treehouse lease + tasks-axi/quota-axi bootstrap contracts"
}

test_no_mistakes_min_version() {
  local label version mode case_dir fakebin out missing n
  missing='MISSING: no-mistakes (install: curl -fsSL https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh | sh)'
  n=0
  while IFS='^' read -r label version mode; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case_dir="$TMP_ROOT/no-mistakes-$n"
    mkdir -p "$case_dir/home"
    mkdir -p "$case_dir/home/config"
    printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
    fakebin=$(make_fake_toolchain "$case_dir")
    add_tasks_axi "$fakebin" "0.1.1"
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
      FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_FAKE_NO_MISTAKES_VERSION="$version" "$ROOT/bin/fm-bootstrap.sh")
    case "$mode" in
      empty)
        [ -z "$out" ] || fail "$label: expected silence, got: $out" ;;
      missing)
        [ "$out" = "$missing" ] || fail "$label: expected '$missing', got: $out" ;;
    esac
  done <<'ROWS'
minimum no-mistakes version is accepted^no-mistakes version v1.31.2 (fake)^empty
newer no-mistakes minor is accepted^no-mistakes version v1.32.0 (fake)^empty
newer no-mistakes major is accepted^no-mistakes version v2.0.0 (fake)^empty
older no-mistakes patch reports an upgrade^no-mistakes version v1.31.1 (fake)^missing
unparseable no-mistakes version reports an upgrade^no-mistakes development build^missing
ROWS
  pass "bootstrap enforces no-mistakes minimum version"
}

test_secondmate_self_check_reports_routed_work_readiness() {
  local case_dir fakebin out
  case_dir="$TMP_ROOT/secondmate-self-check"
  mkdir -p "$case_dir/home/config"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  printf '%s\n' domain > "$case_dir/home/.fm-secondmate-home"
  fakebin=$(make_fake_toolchain "$case_dir")
  rm -f "$fakebin/quota-axi"

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 \
    FM_FAKE_NO_MISTAKES_VERSION="no-mistakes version v1.31.1 (fake)" \
    "$ROOT/bin/fm-bootstrap.sh")

  assert_contains "$out" "MISSING: quota-axi (install: npm install -g quota-axi)" \
    "secondmate self-check test setup should still surface the detailed quota diagnostic"
  assert_contains "$out" "MISSING: no-mistakes (install: curl -fsSL https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh | sh)" \
    "secondmate self-check test setup should still surface the detailed version diagnostic"
  assert_contains "$out" "SECONDMATE_SELF_CHECK: failed: routed-work prerequisites not ready: quota-axi no-mistakes" \
    "secondmate self-check should summarize routed-work readiness failures"
  pass "bootstrap reports secondmate routed-work readiness before accepting work"
}

test_git_is_required_with_supported_install_instruction() {
  local case_dir fakebin bash_env out expected
  case_dir="$TMP_ROOT/git-required"
  mkdir -p "$case_dir/home/config"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  fakebin=$(make_fake_toolchain "$case_dir")
  bash_env="$case_dir/no-git.bash"
  cat > "$bash_env" <<'SH'
command() {
  if [ "${1:-}" = -v ] && [ "${2:-}" = git ]; then
    return 1
  fi
  builtin command "$@"
}
git() {
  return 127
}
SH

  out=$(PATH="$fakebin:$BASE_PATH" BASH_ENV="$bash_env" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  expected="MISSING: git (install: brew install git  # or the platform's package manager)"
  [ "$out" = "$expected" ] || fail "missing git should report the supported install instruction, got: $out"
  pass "bootstrap requires git with an install instruction"
}

test_orca_backend_gates_orca_tool_only_when_selected() {
  local case_dir fakebin out missing_orca
  missing_orca="MISSING: orca (install: brew install orca  # or the platform's package manager)"

  case_dir="$TMP_ROOT/orca-backend-selected"
  mkdir -p "$case_dir/home/config"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  printf '%s\n' orca > "$case_dir/home/config/backend"
  fakebin=$(make_fake_toolchain "$case_dir")
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  [ "$out" = "$missing_orca" ] || fail "backend=orca should require only the Orca-specific missing tool, got: $out"

  case_dir="$TMP_ROOT/orca-backend-not-selected"
  mkdir -p "$case_dir/home/config"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  fakebin=$(make_fake_toolchain "$case_dir")
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  assert_not_contains "$out" "MISSING: orca" "bootstrap should not require orca unless backend=orca is selected"
  pass "bootstrap: backend=orca gates the Orca CLI without requiring it on the default backend"
}

# Build a fake toolchain with tmux REMOVED and the named backend session CLI(s)
# plus jq added, so a backend that must NOT require tmux can be proven silent
# with tmux absent. Echoes the fakebin dir. The removed tmux is what makes these
# cases catch the old "everything but orca demands tmux" bug: with the buggy
# TOOLS list a herdr/zellij/cmux home would report MISSING: tmux here.
make_fake_toolchain_no_tmux() {  # <case-dir> <extra-cli...>
  local dir=$1 fakebin
  shift
  fakebin=$(make_fake_toolchain "$dir")
  rm -f "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" jq "$@"
  printf '%s\n' "$fakebin"
}

test_session_provider_backends_do_not_require_tmux() {
  local backend cli case_dir fakebin out
  # herdr/zellij/cmux are session providers only: they require their own CLI, jq,
  # and treehouse, never tmux. With all genuine deps present and tmux absent,
  # bootstrap must be silent.
  while IFS='^' read -r backend cli; do
    [ -n "$backend" ] || continue
    case_dir="$TMP_ROOT/$backend-no-tmux"
    mkdir -p "$case_dir/home/config"
    printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
    printf '%s\n' "$backend" > "$case_dir/home/config/backend"
    fakebin=$(make_fake_toolchain_no_tmux "$case_dir" "$cli")
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
      FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
    [ -z "$out" ] || fail "backend=$backend with tmux absent but its own deps present should be silent, got: $out"
  done <<'ROWS'
herdr^herdr
zellij^zellij
cmux^cmux
ROWS
  pass "bootstrap: session-provider backends require their own CLI + jq + treehouse, never tmux"
}

test_session_provider_backends_gate_own_cli_not_tmux() {
  local backend cli case_dir fakebin out missing
  # With the backend's OWN session CLI absent (and tmux also absent), bootstrap
  # must fail closed on the genuine dep and never substitute a false tmux demand.
  while IFS='^' read -r backend cli; do
    [ -n "$backend" ] || continue
    case_dir="$TMP_ROOT/$backend-missing-cli"
    mkdir -p "$case_dir/home/config"
    printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
    printf '%s\n' "$backend" > "$case_dir/home/config/backend"
    # Toolchain has jq + treehouse but NOT the session CLI and NOT tmux.
    fakebin=$(make_fake_toolchain_no_tmux "$case_dir")
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
      FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
    if [ "$backend" = herdr ]; then
      missing="MISSING_MANUAL: herdr (instructions: https://herdr.dev)"
    else
      missing="MISSING: $cli"
    fi
    assert_contains "$out" "$missing" "backend=$backend must fail closed on its own missing session CLI"
    if [ "$backend" = herdr ]; then
      assert_not_contains "$out" "MISSING: herdr (install:" \
        "backend=herdr must not advertise manual guidance as an executable install command"
    fi
    assert_not_contains "$out" "MISSING: tmux" "backend=$backend must not demand tmux when its own CLI is missing"
  done <<'ROWS'
herdr^herdr
zellij^zellij
cmux^cmux
ROWS
  pass "bootstrap: a session-provider backend gates its own CLI, never a false tmux requirement"
}

test_herdr_install_requires_manual_action() {
  local out status
  out=$("$ROOT/bin/fm-bootstrap.sh" install herdr 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "install herdr should fail instead of evaluating its manual-install hint"
  [ "$out" = "error: herdr requires manual installation (instructions: https://herdr.dev)" ] \
    || fail "install herdr should return actionable manual-install guidance, got: $out"
  pass "bootstrap: Herdr manual-install guidance is never executed as a shell command"
}

test_cmux_bundled_cli_satisfies_dependency() {
  local case_dir fakebin bundle out
  case_dir="$TMP_ROOT/cmux-bundled-cli"
  mkdir -p "$case_dir/home/config" "$case_dir/bundle"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  printf '%s\n' cmux > "$case_dir/home/config/backend"
  fakebin=$(make_fake_toolchain_no_tmux "$case_dir")
  fm_fake_exit0 "$case_dir/bundle" cmux
  bundle="$case_dir/bundle/cmux"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_BACKEND_CMUX_BUNDLE_BIN="$bundle" FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  [ -z "$out" ] || fail "a usable bundled cmux CLI should satisfy bootstrap without a PATH shim, got: $out"
  pass "bootstrap: the bundled cmux CLI satisfies the active backend dependency"
}

test_unknown_backend_reports_invalid_configuration() {
  local case_dir fakebin out
  case_dir="$TMP_ROOT/unknown-backend"
  mkdir -p "$case_dir/home/config"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  printf '%s\n' bogus > "$case_dir/home/config/backend"
  fakebin=$(make_fake_toolchain "$case_dir")
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  assert_contains "$out" "BACKEND_INVALID: bogus (known: tmux herdr zellij orca cmux)" \
    "bootstrap should report an unknown resolved backend"
  assert_not_contains "$out" "MISSING: tmux" "an unknown backend should not silently fall back to tmux dependencies"
  pass "bootstrap: unknown resolved backends fail closed with an actionable diagnostic"
}

test_json_backends_require_jq_not_tmux() {
  local backend case_dir fakebin bash_env out
  # herdr/zellij/cmux parse their backend's JSON output, so jq is a genuine dep.
  # jq lives in a system BASE_PATH dir on many hosts, so force it missing with a
  # command()/jq() override (the same technique the git-required case uses) to keep
  # the assertion host-independent.
  while IFS='^' read -r backend; do
    [ -n "$backend" ] || continue
    case_dir="$TMP_ROOT/$backend-missing-jq"
    mkdir -p "$case_dir/home/config"
    printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
    printf '%s\n' "$backend" > "$case_dir/home/config/backend"
    # Session CLI present, tmux absent, jq deliberately NOT stubbed and masked below.
    fakebin=$(make_fake_toolchain "$case_dir")
    rm -f "$fakebin/tmux"
    fm_fake_exit0 "$fakebin" "$backend"
    bash_env="$case_dir/no-jq.bash"
    cat > "$bash_env" <<'SH'
command() {
  if [ "${1:-}" = -v ] && [ "${2:-}" = jq ]; then
    return 1
  fi
  builtin command "$@"
}
jq() {
  return 127
}
SH
    out=$(PATH="$fakebin:$BASE_PATH" BASH_ENV="$bash_env" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
      FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
    assert_contains "$out" "MISSING: jq" "backend=$backend must fail closed on missing jq"
    assert_not_contains "$out" "MISSING: tmux" "backend=$backend must not demand tmux when jq is missing"
  done <<'ROWS'
herdr
zellij
cmux
ROWS
  pass "bootstrap: JSON-emitting backends require jq (their genuine dep), never tmux"
}

test_treehouse_lease_check_follows_resolved_backend() {
  local case_dir fakebin out
  # A treehouse that lacks durable --lease support is only a problem for a backend
  # that actually uses treehouse. Orca owns its own worktrees, so an old treehouse
  # must NOT trip MISSING: treehouse under backend=orca...
  case_dir="$TMP_ROOT/orca-old-treehouse"
  mkdir -p "$case_dir/home/config"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  printf '%s\n' orca > "$case_dir/home/config/backend"
  fakebin=$(make_fake_toolchain "$case_dir")
  rm -f "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" orca
  # FM_FAKE_TREEHOUSE_LEASE_HELP unset: the fake treehouse advertises NO --lease.
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    "$ROOT/bin/fm-bootstrap.sh")
  [ -z "$out" ] || fail "backend=orca must not require treehouse (even lease-less) or tmux, got: $out"

  # ...but the same lease-less treehouse IS a problem for a session-provider
  # backend that relies on treehouse for worktrees.
  case_dir="$TMP_ROOT/herdr-old-treehouse"
  mkdir -p "$case_dir/home/config"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  printf '%s\n' herdr > "$case_dir/home/config/backend"
  fakebin=$(make_fake_toolchain_no_tmux "$case_dir" herdr)
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    "$ROOT/bin/fm-bootstrap.sh")
  assert_contains "$out" "MISSING: treehouse" "backend=herdr must still require treehouse with durable lease support"
  assert_not_contains "$out" "MISSING: tmux" "backend=herdr must not demand tmux even when treehouse is too old"
  pass "bootstrap: the treehouse lease check follows the resolved backend's worktree provider"
}

test_treehouse_dirty_idle_slot_audit_reports_read_only() {
  local case_dir root home fakebin status_file calls dirty_slot out
  case_dir="$TMP_ROOT/treehouse-dirty-audit"
  root="$case_dir/root"
  home="$case_dir/home"
  dirty_slot="$case_dir/dirty-slot"
  mkdir -p "$root" "$home/config" "$dirty_slot/claude-playground"
  printf '%s\n' manual > "$home/config/backlog-backend"
  printf '%s\n' 'unlanded notes' > "$dirty_slot/claude-playground/WIP.md"
  fakebin=$(make_fake_toolchain "$case_dir")
  status_file="$case_dir/treehouse-status.txt"
  calls="$case_dir/treehouse-calls.txt"
  cat > "$status_file" <<EOF
1     available    $case_dir/available-slot
2     dirty        $dirty_slot
3     in-use       $case_dir/in-use-slot
                   zsh (12345)
EOF

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    FM_BOOTSTRAP_DETECT_ONLY=1 FM_FAKE_TREEHOUSE_LEASE_HELP=1 \
    FM_FAKE_TREEHOUSE_STATUS_FILE="$status_file" FM_FAKE_TREEHOUSE_CALLS="$calls" \
    "$ROOT/bin/fm-bootstrap.sh")

  assert_contains "$out" "TREEHOUSE_POOL: dirty idle slot 2 at $dirty_slot - inspect before cleanup; no changes made" \
    "bootstrap should surface dirty idle treehouse slots"
  assert_not_contains "$out" "available-slot" "audit should ignore available slots"
  assert_not_contains "$out" "in-use-slot" "audit should ignore in-use slots"
  assert_present "$dirty_slot/claude-playground/WIP.md" "dirty idle audit must not clean slot contents"
  assert_grep "status" "$calls" "audit should call treehouse status"
  assert_no_grep "return" "$calls" "audit must not call treehouse return"
  assert_no_grep "prune" "$calls" "audit must not call treehouse prune"
  pass "bootstrap: dirty idle treehouse slot audit is read-only and actionable"
}

# Pools are per-repo and `treehouse status` resolves the pool from the working
# directory, so an audit pinned to FM_ROOT would only ever see firstmate's own
# pool. Crewmate ship/scout slots - the ones that can strand unlanded project
# work - are leased inside projects/<name>, so the audit must sweep those too.
test_treehouse_dirty_idle_slot_audit_sweeps_project_pools() {
  local case_dir root home fakebin by_dir calls proj_slot root_slot out
  case_dir="$TMP_ROOT/treehouse-dirty-audit-projects"
  root="$case_dir/root"
  home="$case_dir/home"
  proj_slot="$case_dir/proj-dirty-slot"
  root_slot="$case_dir/root-dirty-slot"
  mkdir -p "$root" "$home/config" "$home/projects/notes" "$proj_slot" "$root_slot"
  git init -q -b main "$home/projects/alpha"
  git init -q -b main "$home/projects/beta"
  printf '%s\n' manual > "$home/config/backlog-backend"
  fakebin=$(make_fake_toolchain "$case_dir")
  by_dir="$case_dir/status-by-dir"
  calls="$case_dir/treehouse-calls.txt"
  mkdir -p "$by_dir"
  printf '1     dirty        %s\n' "$root_slot" > "$by_dir/root"
  printf '4     dirty        %s\n' "$proj_slot" > "$by_dir/alpha"
  printf '5     available    %s\n' "$case_dir/beta-free" > "$by_dir/beta"
  printf '6     dirty        %s\n' "$case_dir/notes-slot" > "$by_dir/notes"

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    FM_BOOTSTRAP_DETECT_ONLY=1 FM_FAKE_TREEHOUSE_LEASE_HELP=1 \
    FM_FAKE_TREEHOUSE_STATUS_BY_DIR="$by_dir" FM_FAKE_TREEHOUSE_CALLS="$calls" \
    "$ROOT/bin/fm-bootstrap.sh")

  assert_contains "$out" "TREEHOUSE_POOL: dirty idle slot 1 at $root_slot" \
    "audit should still report the firstmate pool"
  assert_contains "$out" "TREEHOUSE_POOL: dirty idle slot 4 at $proj_slot" \
    "audit should report dirty idle slots in a project clone's pool"
  assert_not_contains "$out" "beta-free" "audit should ignore available project slots"
  assert_grep "status in $(cd "$home/projects/alpha" && pwd -P)" "$calls" "audit should scan each project clone's pool"
  # A non-repo directory under projects/ owns no pool of its own, so it must not
  # cost a treehouse fork or report some enclosing repo's slots as its own.
  assert_not_contains "$out" "notes-slot" "audit should not probe a non-repo directory under projects/"
  assert_no_grep "status in $(cd "$home/projects/notes" && pwd -P)" "$calls" \
    "audit should skip non-repo directories under projects/"
  assert_no_grep "return" "$calls" "project pool audit must not call treehouse return"
  assert_no_grep "prune" "$calls" "project pool audit must not call treehouse prune"
  pass "bootstrap: dirty idle treehouse slot audit sweeps project clone pools, skipping non-repo directories"
}

# The sweep forks `treehouse status` per clone on the always-executed detect path,
# so one hung or lock-blocked pool must degrade to a partial report instead of
# wedging session start. The audit is advisory and changes nothing, so hitting the
# bound must stay SILENT - a read-only sweep that reports its own incompleteness
# would put a permanent actionable line in front of the captain forever.
test_treehouse_dirty_idle_slot_audit_is_bounded() {
  local case_dir root home fakebin by_dir root_slot out start elapsed
  case_dir="$TMP_ROOT/treehouse-dirty-audit-timeout"
  root="$case_dir/root"
  home="$case_dir/home"
  root_slot="$case_dir/root-dirty-slot"
  mkdir -p "$root" "$home/config" "$root_slot"
  git init -q -b main "$home/projects/hung"
  printf '%s\n' manual > "$home/config/backlog-backend"
  fakebin=$(make_fake_toolchain "$case_dir")
  by_dir="$case_dir/status-by-dir"
  mkdir -p "$by_dir"
  printf '1     dirty        %s\n' "$root_slot" > "$by_dir/root"
  printf 'FM_FAKE_TREEHOUSE_HANG\n' > "$by_dir/hung"

  start=$(date +%s)
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    FM_BOOTSTRAP_DETECT_ONLY=1 FM_FAKE_TREEHOUSE_LEASE_HELP=1 \
    FM_TREEHOUSE_AUDIT_TIMEOUT=2 \
    FM_FAKE_TREEHOUSE_STATUS_BY_DIR="$by_dir" \
    "$ROOT/bin/fm-bootstrap.sh")
  elapsed=$(( $(date +%s) - start ))

  assert_contains "$out" "TREEHOUSE_POOL: dirty idle slot 1 at $root_slot" \
    "a bounded audit must still relay the findings it completed"
  assert_not_contains "$out" "timed out" \
    "an advisory read-only sweep must degrade quietly, not print a timeout diagnostic"
  [ "$elapsed" -lt 20 ] || fail "bounded audit took ${elapsed}s; the hung pool was not cut off"
  pass "bootstrap: the dirty idle treehouse slot audit is bounded and degrades silently to partial findings"
}

# One `treehouse status` against a real pool costs SECONDS, so a bound tight enough
# to cut off a wedged provider must still be loose enough that a merely slow but
# healthy pool is not routinely dropped and its findings silently lost.
test_treehouse_dirty_idle_slot_audit_default_bound_tolerates_a_slow_pool() {
  local case_dir root home fakebin by_dir slow_slot out
  case_dir="$TMP_ROOT/treehouse-audit-default-bound"
  root="$case_dir/root"
  home="$case_dir/home"
  slow_slot="$case_dir/slow-dirty-slot"
  mkdir -p "$root" "$home/config" "$slow_slot"
  printf '%s\n' manual > "$home/config/backlog-backend"
  fakebin=$(make_fake_toolchain "$case_dir")
  by_dir="$case_dir/status-by-dir"
  mkdir -p "$by_dir"
  printf 'FM_FAKE_TREEHOUSE_SLOW 10\n1     dirty        %s\n' "$slow_slot" > "$by_dir/root"

  # Both bounds deliberately unset: this exercises the DEFAULTS.
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    FM_BOOTSTRAP_DETECT_ONLY=1 FM_FAKE_TREEHOUSE_LEASE_HELP=1 \
    FM_FAKE_TREEHOUSE_STATUS_BY_DIR="$by_dir" \
    "$ROOT/bin/fm-bootstrap.sh")

  assert_contains "$out" "TREEHOUSE_POOL: dirty idle slot 1 at $slow_slot" \
    "the default per-pool bound must tolerate a pool that answers slowly"
  pass "bootstrap: the default per-pool audit bound tolerates a slow but healthy pool"
}

# The bound is PER POOL, not one budget for the whole sweep. A single lock-blocked
# provider must cost only its own pool's allowance: the healthy pools behind it are
# exactly the ones that can still be holding stranded work, so starving them would
# make the audit useless precisely when a pool is misbehaving.
test_treehouse_dirty_idle_slot_audit_wedged_pool_does_not_starve_the_rest() {
  local case_dir root home fakebin by_dir late_slot out start elapsed
  case_dir="$TMP_ROOT/treehouse-audit-per-pool"
  root="$case_dir/root"
  home="$case_dir/home"
  late_slot="$case_dir/late-dirty-slot"
  mkdir -p "$root" "$home/config" "$late_slot"
  printf '%s\n' manual > "$home/config/backlog-backend"
  # Swept in order: FM_ROOT, then projects/* alphabetically - so the wedged clone
  # is reached BEFORE the healthy one that owns the finding.
  git init -q -b main "$home/projects/a-hung"
  git init -q -b main "$home/projects/z-healthy"
  fakebin=$(make_fake_toolchain "$case_dir")
  by_dir="$case_dir/status-by-dir"
  mkdir -p "$by_dir"
  printf 'FM_FAKE_TREEHOUSE_HANG\n' > "$by_dir/a-hung"
  printf '7     dirty        %s\n' "$late_slot" > "$by_dir/z-healthy"

  start=$(date +%s)
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    FM_BOOTSTRAP_DETECT_ONLY=1 FM_FAKE_TREEHOUSE_LEASE_HELP=1 \
    FM_TREEHOUSE_AUDIT_POOL_TIMEOUT=2 FM_TREEHOUSE_AUDIT_TIMEOUT=30 \
    FM_FAKE_TREEHOUSE_STATUS_BY_DIR="$by_dir" \
    "$ROOT/bin/fm-bootstrap.sh")
  elapsed=$(( $(date +%s) - start ))

  assert_contains "$out" "TREEHOUSE_POOL: dirty idle slot 7 at $late_slot" \
    "a pool swept after a wedged one must still be reported"
  assert_not_contains "$out" "timed out" \
    "dropping a wedged pool must stay silent"
  [ "$elapsed" -lt 20 ] || fail "sweep took ${elapsed}s; the wedged pool spent more than its own bound"
  pass "bootstrap: a wedged pool is dropped at its own bound and the sweep continues"
}

# Per-pool bounds alone would still multiply by clone count, so the sweep must also
# stop at a fixed overall deadline: an advisory read-only audit must never add
# material session-start latency, however many clones a home registers.
test_treehouse_dirty_idle_slot_audit_total_cost_does_not_grow_with_clones() {
  local case_dir root home fakebin by_dir out start elapsed i
  case_dir="$TMP_ROOT/treehouse-audit-total-cap"
  root="$case_dir/root"
  home="$case_dir/home"
  mkdir -p "$root" "$home/config"
  printf '%s\n' manual > "$home/config/backlog-backend"
  fakebin=$(make_fake_toolchain "$case_dir")
  by_dir="$case_dir/status-by-dir"
  mkdir -p "$by_dir"
  # Eight wedged clones: unbounded in total, a 3s per-pool bound would cost 24s.
  for i in 1 2 3 4 5 6 7 8; do
    git init -q -b main "$home/projects/hung$i"
    printf 'FM_FAKE_TREEHOUSE_HANG\n' > "$by_dir/hung$i"
  done

  start=$(date +%s)
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    FM_BOOTSTRAP_DETECT_ONLY=1 FM_FAKE_TREEHOUSE_LEASE_HELP=1 \
    FM_TREEHOUSE_AUDIT_POOL_TIMEOUT=3 FM_TREEHOUSE_AUDIT_TIMEOUT=6 \
    FM_FAKE_TREEHOUSE_STATUS_BY_DIR="$by_dir" \
    "$ROOT/bin/fm-bootstrap.sh")
  elapsed=$(( $(date +%s) - start ))

  assert_not_contains "$out" "TREEHOUSE_POOL:" "wedged pools yield no findings and no diagnostic"
  [ "$elapsed" -lt 15 ] || fail "sweep took ${elapsed}s; the overall deadline did not cap eight wedged pools"
  pass "bootstrap: the whole-sweep deadline caps total audit cost regardless of clone count"
}

# The audit is only meaningful for a backend whose worktrees ARE treehouse pool
# slots. Orca owns its own worktrees, so an orca home with treehouse merely
# installed must not fork `treehouse status` per clone at every session start -
# the same resolved-backend rule the treehouse lease-support check follows.
test_treehouse_dirty_idle_slot_audit_follows_resolved_backend() {
  local case_dir root home fakebin status_file calls dirty_slot out
  case_dir="$TMP_ROOT/treehouse-dirty-audit-orca"
  root="$case_dir/root"
  home="$case_dir/home"
  dirty_slot="$case_dir/dirty-slot"
  mkdir -p "$root" "$home/config" "$dirty_slot"
  printf '%s\n' manual > "$home/config/backlog-backend"
  printf '%s\n' orca > "$home/config/backend"
  fakebin=$(make_fake_toolchain "$case_dir")
  rm -f "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" orca
  status_file="$case_dir/treehouse-status.txt"
  calls="$case_dir/treehouse-calls.txt"
  printf '1     dirty        %s\n' "$dirty_slot" > "$status_file"

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    FM_BOOTSTRAP_DETECT_ONLY=1 FM_FAKE_TREEHOUSE_LEASE_HELP=1 \
    FM_FAKE_TREEHOUSE_STATUS_FILE="$status_file" FM_FAKE_TREEHOUSE_CALLS="$calls" \
    "$ROOT/bin/fm-bootstrap.sh")

  assert_not_contains "$out" "TREEHOUSE_POOL:" "backend=orca must not run a treehouse pool audit"
  assert_no_grep "status" "$calls" "backend=orca must not fork treehouse status at session start"
  pass "bootstrap: the dirty idle pool audit follows the resolved backend's worktree provider"
}

# A zero bound is the operator turning this advisory sweep off. It must go quiet,
# not kill the sweep before it reads anything and then print a TREEHOUSE_POOL
# timeout line - an actionable diagnostic - on every session start forever.
test_treehouse_dirty_idle_slot_audit_zero_timeout_disables_it() {
  local case_dir root home fakebin status_file calls dirty_slot out
  case_dir="$TMP_ROOT/treehouse-dirty-audit-off"
  root="$case_dir/root"
  home="$case_dir/home"
  dirty_slot="$case_dir/dirty-slot"
  mkdir -p "$root" "$home/config" "$dirty_slot"
  printf '%s\n' manual > "$home/config/backlog-backend"
  fakebin=$(make_fake_toolchain "$case_dir")
  status_file="$case_dir/treehouse-status.txt"
  calls="$case_dir/treehouse-calls.txt"
  printf '1     dirty        %s\n' "$dirty_slot" > "$status_file"

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    FM_BOOTSTRAP_DETECT_ONLY=1 FM_FAKE_TREEHOUSE_LEASE_HELP=1 \
    FM_TREEHOUSE_AUDIT_TIMEOUT=0 \
    FM_FAKE_TREEHOUSE_STATUS_FILE="$status_file" FM_FAKE_TREEHOUSE_CALLS="$calls" \
    "$ROOT/bin/fm-bootstrap.sh")

  assert_not_contains "$out" "TREEHOUSE_POOL:" "a zero audit bound must print no pool diagnostic at all"
  assert_no_grep "status in " "$calls" "a disabled audit must not fork treehouse status"
  pass "bootstrap: FM_TREEHOUSE_AUDIT_TIMEOUT=0 turns the pool audit off silently"
}

test_fleet_sync_timeout_scales_with_origin_backed_project_count() {
  local case_dir home fakebin fake_root out
  case_dir="$TMP_ROOT/fleet-timeout-scaled"
  home="$case_dir/home"
  mkdir -p "$home/config"
  printf '%s\n' manual > "$home/config/backlog-backend"
  add_origin_backed_projects "$home" 18
  add_no_origin_projects "$home" 3
  fakebin=$(make_fake_toolchain "$case_dir")
  fake_root=$(make_fake_fleet_sync_root "$case_dir")

  out=$(run_bootstrap_timeout_case "$home" "$fake_root" "$fakebin")

  assert_contains "$out" $'FLEET_SYNC: alpha: synced\nFLEET_SYNC: beta: skipped: no origin remote' "bootstrap timeout should relay partial fleet-sync output first"
  assert_timeout_report "$out" 59
  pass "bootstrap computes a fleet-size-aware default timeout and preserves partial fleet-sync output"
}

test_fleet_sync_timeout_floor_preserves_small_fleets() {
  local case_dir home fakebin fake_root out
  case_dir="$TMP_ROOT/fleet-timeout-small"
  home="$case_dir/home"
  mkdir -p "$home/config"
  printf '%s\n' manual > "$home/config/backlog-backend"
  add_origin_backed_projects "$home" 2
  fakebin=$(make_fake_toolchain "$case_dir")
  fake_root=$(make_fake_fleet_sync_root "$case_dir")

  out=$(run_bootstrap_timeout_case "$home" "$fake_root" "$fakebin")

  assert_timeout_report "$out" 20
  pass "bootstrap keeps the quick 20s default for small fleets"
}

test_fleet_sync_timeout_explicit_override_wins() {
  local case_dir home fakebin fake_root out
  case_dir="$TMP_ROOT/fleet-timeout-override"
  home="$case_dir/home"
  mkdir -p "$home/config"
  printf '%s\n' manual > "$home/config/backlog-backend"
  add_origin_backed_projects "$home" 18
  fakebin=$(make_fake_toolchain "$case_dir")
  fake_root=$(make_fake_fleet_sync_root "$case_dir")

  out=$(run_bootstrap_timeout_case "$home" "$fake_root" "$fakebin" 7)

  assert_timeout_report "$out" 7
  assert_not_contains "$out" "timeout=59s" "explicit override should not be replaced by the computed timeout"
  pass "bootstrap preserves FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT as an explicit override"
}

test_fleet_sync_timeout_empty_override_uses_default() {
  local case_dir home fakebin fake_root out
  case_dir="$TMP_ROOT/fleet-timeout-empty-override"
  home="$case_dir/home"
  mkdir -p "$home/config"
  printf '%s\n' manual > "$home/config/backlog-backend"
  add_origin_backed_projects "$home" 18
  fakebin=$(make_fake_toolchain "$case_dir")
  fake_root=$(make_fake_fleet_sync_root "$case_dir")

  out=$(run_bootstrap_timeout_case "$home" "$fake_root" "$fakebin" "")

  assert_timeout_report "$out" 59
  assert_not_contains "$out" "timeout=20s" "blank timeout env should not force the legacy floor on a large fleet"
  pass "bootstrap treats a blank timeout override as unset"
}

test_fleet_sync_timeout_is_computed_before_launch() {
  local case_dir home fakebin fake_root out started_marker git_record
  case_dir="$TMP_ROOT/fleet-timeout-launch-order"
  home="$case_dir/home"
  started_marker="$case_dir/fleet-started"
  git_record="$case_dir/git-after-start"
  mkdir -p "$home/config"
  printf '%s\n' manual > "$home/config/backlog-backend"
  add_origin_backed_projects "$home" 3
  fakebin=$(make_fake_toolchain "$case_dir")
  fake_root=$(make_fake_fleet_sync_root "$case_dir")

  out=$(run_bootstrap_timeout_case "$home" "$fake_root" "$fakebin" __unset__ "$started_marker" "$git_record" 1)

  [ ! -s "$git_record" ] || fail "fleet sync launched before timeout scan finished: $(tr '\n' ';' < "$git_record")"
  assert_contains "$out" $'FLEET_SYNC: alpha: synced\nFLEET_SYNC: beta: skipped: no origin remote' "launch-order case should relay partial fleet-sync output before reporting its timeout"
  assert_timeout_report "$out" 20
  pass "bootstrap computes the timeout before launching fleet sync"
}

make_routine_bootstrap_fixture() {
  local case_dir=$1 fakebin root home sm c1
  root="$case_dir/root"
  home="$case_dir/home"
  sm="$case_dir/sm"
  fm_git_identity
  mkdir -p "$home/config" "$home/state"
  printf '%s\n' codex > "$home/config/crew-harness"
  printf '%s\n' '{"rules":[{"when":"normal work","use":{"harness":"codex"}}],"default":{"harness":"claude","effort":"low"}}' \
    > "$home/config/crew-dispatch.json"
  git init -q -b main "$root"
  {
    printf '%s\n' '.fm-secondmate-home'
    printf '%s\n' 'config/crew-harness'
    printf '%s\n' 'config/crew-dispatch.json'
  } > "$root/.gitignore"
  printf '%s\n' 'instructions' > "$root/AGENTS.md"
  mkdir -p "$root/bin" "$root/.agents/skills"
  printf '%s\n' 'echo ok' > "$root/bin/fm-spawn.sh"
  printf '%s\n' 'skill' > "$root/.agents/skills/example.md"
  git -C "$root" add -A
  git -C "$root" commit -qm initial
  c1=$(git -C "$root" rev-parse HEAD)
  git -C "$root" worktree add -q --detach "$sm" "$c1"
  printf '%s\n' sm > "$sm/.fm-secondmate-home"
  {
    printf 'window=firstmate:fm-sm\n'
    printf 'kind=secondmate\n'
    printf 'harness=codex\n'
    printf 'home=%s\n' "$sm"
  } > "$home/state/sm.meta"
  fakebin=$(make_fake_toolchain "$case_dir")
  add_real_jq "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = display-message ]; then
  printf '%s\n' codex
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s|%s|%s\n' "$root" "$home" "$fakebin"
}

run_routine_bootstrap_fixture() {
  local shell=$1 case_dir=$2 fixture root home fakebin
  fixture=$(make_routine_bootstrap_fixture "$case_dir")
  root=${fixture%%|*}
  fixture=${fixture#*|}
  home=${fixture%%|*}
  fakebin=${fixture#*|}
  PATH="$fakebin:$BASE_PATH" FM_BACKEND=tmux FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 \
    "$shell" "$ROOT/bin/fm-bootstrap.sh"
}

test_routine_bootstrap_confirmations_are_silent() {
  local out
  out=$(run_routine_bootstrap_fixture bash "$TMP_ROOT/routine-silent")
  [ -z "$out" ] || fail "routine bootstrap confirmations should be silent, got: $out"
  pass "bootstrap keeps routine tasks-axi, harness, dispatch, and already-live liveness confirmations silent"
}

test_routine_bootstrap_contract_runs_under_system_bash() {
  local out
  [ -x /bin/bash ] || { pass "bootstrap routine contract skipped without /bin/bash"; return; }
  out=$(run_routine_bootstrap_fixture /bin/bash "$TMP_ROOT/routine-bash")
  [ -z "$out" ] || fail "routine bootstrap contract should be silent under /bin/bash, got: $out"
  pass "bootstrap routine contract runs under system /bin/bash"
}

test_bootstrap_info_is_no_load_and_actionable_lines_trigger() {
  local trigger
  # shellcheck disable=SC2016 # The backtick-delimited skill names are literal Markdown.
  trigger=$(sed -n '/- `bootstrap-diagnostics`/,/- `diagnostic-reasoning`/p' "$ROOT/AGENTS.md")
  assert_contains "$trigger" "actionable diagnostic line" "bootstrap-diagnostics trigger should be action-scoped"
  assert_contains "$trigger" "BOOTSTRAP_INFO:" "bootstrap-diagnostics trigger should classify BOOTSTRAP_INFO as no-load"
  assert_contains "$trigger" "TREEHOUSE_POOL:" "bootstrap-diagnostics trigger should include dirty idle slot audits"
  assert_not_contains "$trigger" "TASKS_AXI:" "tasks-axi availability must not trigger diagnostics loading"
  assert_not_contains "$trigger" "CREW_HARNESS_OVERRIDE:" "harness override confirmation must not trigger diagnostics loading"
  assert_not_contains "$trigger" "CREW_DISPATCH: active" "active dispatch confirmation must not trigger diagnostics loading"
  assert_not_contains "$trigger" "already-live" "already-live secondmate liveness must not trigger diagnostics loading"
  pass "bootstrap diagnostics trigger excludes benign lines and keeps actionable prefixes"
}

test_crew_dispatch_active_rules_are_verbose_bootstrap_info() {
  local case_dir fakebin out expect
  case_dir="$TMP_ROOT/dispatch-active"
  mkdir -p "$case_dir/home/config"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  printf '%s\n' '{"rules":[{"when":"fresh news","use":{"harness":"grok"},"why":"current context"},{"when":"big feature","use":[{"harness":"claude","model":"claude-sonnet-5","effort":"high"},{"harness":"codex","model":"gpt-5.5","effort":"high"}],"select":"quota-balanced"}],"default":{"harness":"claude","model":"haiku","effort":"low"}}' > "$case_dir/home/config/crew-dispatch.json"
  fakebin=$(make_fake_toolchain "$case_dir")
  add_real_jq "$fakebin"

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  [ -z "$out" ] || fail "active dispatch profile should be silent by default, got: $out"

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_BOOTSTRAP_VERBOSE_FACTS=1 FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")

  expect=$'BOOTSTRAP_INFO: crew dispatch active config/crew-dispatch.json\nBOOTSTRAP_INFO: crew dispatch rule: fresh news -> grok\nBOOTSTRAP_INFO: crew dispatch rule: big feature -> quota-balanced[claude/claude-sonnet-5/high, codex/gpt-5.5/high]\nBOOTSTRAP_INFO: crew dispatch default: claude/haiku/low'
  [ "$out" = "$expect" ] || fail "active dispatch verbose info block mismatch"$'\n'"expected: $expect"$'\n'"actual:   $out"
  pass "bootstrap surfaces active crew-dispatch rules only as verbose BOOTSTRAP_INFO"
}

test_crew_dispatch_validation() {
  local label body expect mode case_dir fakebin out n
  n=0
  while IFS='^' read -r label body mode expect; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case_dir="$TMP_ROOT/dispatch-$n"
    mkdir -p "$case_dir/home/config"
    printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
    printf '%s\n' "$body" > "$case_dir/home/config/crew-dispatch.json"
    fakebin=$(make_fake_toolchain "$case_dir")
    add_real_jq "$fakebin"
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
      FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
    case "$mode" in
      empty)
        [ -z "$out" ] || fail "$label: expected silence, got: $out" ;;
      exact)
        [ "$out" = "$expect" ] || fail "$label: expected '$expect', got: $out" ;;
      grep)
        printf '%s\n' "$out" | grep -Fx "$expect" >/dev/null || fail "$label: missing '$expect' (got: $out)" ;;
    esac
  done <<'ROWS'
malformed dispatch config is flagged^{"rules":[^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - malformed JSON
unverified dispatch harness is flagged^{"rules":[{"when":"anything","use":{"harness":"spaceship"}}],"default":{"harness":"codex"}}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - unverified harness: spaceship
unsupported codex max effort is flagged^{"rules":[{"when":"big feature","use":{"harness":"codex","model":"gpt-5","effort":"max"}}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - invalid effort: codex:max
unsupported grok max effort is flagged^{"rules":[{"when":"deep current work","use":{"harness":"grok","model":"grok-4","effort":"max"}}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - invalid effort: grok:max
unsupported grok xhigh effort is flagged^{"rules":[{"when":"deep current work","use":{"harness":"grok","model":"grok-4","effort":"xhigh"}}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - invalid effort: grok:xhigh
pi max effort is accepted^{"rules":[{"when":"deep coding","use":{"harness":"pi","model":"openai-codex/gpt-5.6-sol","effort":"max"}}]}^empty^
omp xhigh effort is accepted^{"rules":[{"when":"omp work","use":{"harness":"omp","model":"sonnet","effort":"xhigh"}}]}^empty^
unsupported omp max effort is flagged^{"rules":[{"when":"omp work","use":{"harness":"omp","model":"sonnet","effort":"max"}}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - invalid effort: omp:max
unsupported opencode effort is flagged^{"rules":[{"when":"opencode work","use":{"harness":"opencode","model":"anthropic/claude-sonnet-4-5","effort":"high"}}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - invalid effort: opencode:high
array use with quota-balanced is accepted^{"rules":[{"when":"big feature","use":[{"harness":"claude","model":"claude-sonnet-5","effort":"high"},{"harness":"codex","model":"gpt-5.5","effort":"high"}],"select":"quota-balanced"}]}^empty^
array use without select is accepted^{"rules":[{"when":"big feature","use":[{"harness":"claude"},{"harness":"codex"}]}]}^empty^
empty array use is flagged^{"rules":[{"when":"big feature","use":[]}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - each rule needs at least one use profile
array profile without harness is flagged^{"rules":[{"when":"big feature","use":[{"model":"gpt-5.5"}]}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - each use profile needs harness
unknown select is flagged^{"rules":[{"when":"big feature","use":[{"harness":"claude"},{"harness":"codex"}],"select":"mystery"}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - unknown select: mystery
array profile unsupported effort is flagged^{"rules":[{"when":"big feature","use":[{"harness":"codex","effort":"max"}]}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - invalid effort: codex:max
ROWS
  pass "bootstrap validates crew-dispatch.json and reports malformed or unverified configs"
}

test_bootstrap_reporting
test_no_mistakes_min_version
test_secondmate_self_check_reports_routed_work_readiness
test_git_is_required_with_supported_install_instruction
test_orca_backend_gates_orca_tool_only_when_selected
test_session_provider_backends_do_not_require_tmux
test_session_provider_backends_gate_own_cli_not_tmux
test_herdr_install_requires_manual_action
test_cmux_bundled_cli_satisfies_dependency
test_unknown_backend_reports_invalid_configuration
test_json_backends_require_jq_not_tmux
test_treehouse_lease_check_follows_resolved_backend
test_treehouse_dirty_idle_slot_audit_reports_read_only
test_treehouse_dirty_idle_slot_audit_sweeps_project_pools
test_treehouse_dirty_idle_slot_audit_is_bounded
test_treehouse_dirty_idle_slot_audit_default_bound_tolerates_a_slow_pool
test_treehouse_dirty_idle_slot_audit_wedged_pool_does_not_starve_the_rest
test_treehouse_dirty_idle_slot_audit_total_cost_does_not_grow_with_clones
test_treehouse_dirty_idle_slot_audit_follows_resolved_backend
test_treehouse_dirty_idle_slot_audit_zero_timeout_disables_it
test_fleet_sync_timeout_scales_with_origin_backed_project_count
test_fleet_sync_timeout_floor_preserves_small_fleets
test_fleet_sync_timeout_explicit_override_wins
test_fleet_sync_timeout_empty_override_uses_default
test_fleet_sync_timeout_is_computed_before_launch
test_routine_bootstrap_confirmations_are_silent
test_routine_bootstrap_contract_runs_under_system_bash
test_bootstrap_info_is_no_load_and_actionable_lines_trigger
test_crew_dispatch_active_rules_are_verbose_bootstrap_info
test_crew_dispatch_validation
