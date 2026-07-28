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
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  if [ "${FM_FAKE_TREEHOUSE_LEASE_HELP:-}" = 1 ]; then
    printf '%s\n' 'Usage: treehouse get [--lease] [--lease-holder <holder>]'
  else
    printf '%s\n' 'Usage: treehouse get'
  fi
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  # no-mistakes must be present AND expose the `watch` subcommand firstmate's
  # direct-PR monitor depends on. The stub answers `watch --help` per
  # FM_FAKE_NM_WATCH: `ok`/unset = compatible (documents --pr), `missing` = an old
  # build that lacks the subcommand, `error` = an unexpected crash. Any other
  # invocation just succeeds, so `command -v no-mistakes` still passes.
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = watch ] && [ "${2:-}" = --help ]; then
  case "${FM_FAKE_NM_WATCH:-ok}" in
    missing)
      echo 'A new version of no-mistakes is available: v1.34.0 -> v1.40.3' >&2
      echo 'unknown command "watch" for "no-mistakes"' >&2
      exit 1 ;;
    error)
      echo 'panic: runtime error' >&2
      exit 2 ;;
    *)
      printf '%s\n' 'Usage:' '  no-mistakes watch --pr <url> [flags]' \
        'Flags:' '      --pr string   URL of the pull/merge request to watch (required)'
      exit 0 ;;
  esac
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  add_tasks_axi "$fakebin" "0.1.1"
  add_quota_axi "$fakebin"
  printf '%s\n' "$fakebin"
}

# git stub for the Codebase-detection test: answers `git [-C <dir>] remote
# get-url origin` from <dir>/.origin-url and fails every other invocation, so
# `command -v git` still succeeds, the worktree-tangle check stays inert (its
# first call, rev-parse --is-inside-work-tree, gets a non-zero and bails), and
# codebase detection is deterministic without depending on live git repos.
add_fake_git_origin_reader() {
  local fakebin=$1
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
dir=.
while [ $# -gt 0 ]; do
  case "$1" in
    -C) dir=$2; shift 2 ;;
    remote)
      if [ "${2:-}" = get-url ] && [ "${3:-}" = origin ]; then
        [ -f "$dir/.origin-url" ] || exit 1
        cat "$dir/.origin-url"
        exit 0
      fi
      exit 1 ;;
    *) shift ;;
  esac
done
exit 1
SH
  chmod +x "$fakebin/git"
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
# The partial output is on disk from here on; the fake sleep waits for this marker
# so the bootstrap's fake clock cannot time out before the child has written.
[ -z "${FM_FAKE_FLEET_SYNC_OUTPUT_MARKER:-}" ] || : > "$FM_FAKE_FLEET_SYNC_OUTPUT_MARKER"
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
  local home=$1 fake_root=$2 fakebin=$3 override started_marker git_record wait_for_marker output_marker
  override=__unset__
  started_marker=${5:-}
  git_record=${6:-}
  wait_for_marker=${7:-0}
  output_marker="$fake_root/fleet-sync-output"
  rm -f "$output_marker"
  [ "$#" -lt 4 ] || override=$4
  (
    # shellcheck disable=SC2317,SC2329 # Exported and invoked by the bootstrap subprocess.
    sleep() {
      local inc=${1:-1} tries
      # Yield real time until the fleet-sync child has flushed its partial output,
      # then advance the fake clock. A fixed number of short yields loses this race
      # under load and drops the partial output the timeout path must relay.
      if [ -n "${FM_FAKE_FLEET_SYNC_OUTPUT_MARKER:-}" ]; then
        tries=0
        while [ "$tries" -lt 300 ] && [ ! -e "$FM_FAKE_FLEET_SYNC_OUTPUT_MARKER" ]; do
          command sleep 0.01
          tries=$((tries + 1))
        done
      fi
      SECONDS=$((SECONDS + inc))
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
        FM_FAKE_FLEET_SYNC_OUTPUT_MARKER="$output_marker" \
        FM_FAKE_GIT_SYNC_STARTED_RECORD="$git_record" \
        FM_FAKE_GIT_WAIT_FOR_FLEET_START="$wait_for_marker" \
        FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null
    else
      PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$fake_root" \
        FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT="$override" \
        FM_FAKE_FLEET_SYNC_STARTED_MARKER="$started_marker" \
        FM_FAKE_FLEET_SYNC_OUTPUT_MARKER="$output_marker" \
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
treehouse without --lease reports an upgrade, gh auth is fine^0^0.1.1^1^-^grep^MISSING: treehouse (install: git clone https://code.byted.org/obric/treehouse.git && cd treehouse && git checkout v2.0.1 && make install VERSION=v2.0.1  # requires Go 1.25+)^NEEDS_GH_AUTH
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

test_no_mistakes_present_or_internal_source() {
  local case_dir fakebin out missing
  missing='MISSING: no-mistakes (install: git clone https://code.byted.org/obric/no-mistakes.git && cd no-mistakes && make install  # requires Go 1.25+)'
  case_dir="$TMP_ROOT/no-mistakes"
  mkdir -p "$case_dir/home/config"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  fakebin=$(make_fake_toolchain "$case_dir")

  # Present AND compatible: a build that exposes `watch` draws no line at all.
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_FAKE_NM_WATCH=ok "$ROOT/bin/fm-bootstrap.sh")
  [ -z "$out" ] || fail "compatible no-mistakes: expected silence, got: $out"

  # Present but too old (no `watch` subcommand): a distinct NM_INCOMPATIBLE
  # diagnostic, NOT the MISSING (not-installed) line, and it suggests the upgrade
  # without running it.
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_FAKE_NM_WATCH=missing "$ROOT/bin/fm-bootstrap.sh")
  assert_contains "$out" "NM_INCOMPATIBLE: no-mistakes is installed but too old" \
    "old no-mistakes: expected NM_INCOMPATIBLE diagnostic, got: $out"
  assert_contains "$out" "upgrade: no-mistakes update" \
    "old no-mistakes: diagnostic must suggest the upgrade command, got: $out"
  assert_not_contains "$out" "MISSING: no-mistakes" \
    "old no-mistakes: incompatibility must not be misreported as not-installed, got: $out"

  # An unexpected `watch --help` failure is treated as incompatible (fail closed),
  # never silently assumed compatible.
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_FAKE_NM_WATCH=error "$ROOT/bin/fm-bootstrap.sh")
  assert_contains "$out" "NM_INCOMPATIBLE" \
    "erroring no-mistakes: expected NM_INCOMPATIBLE, got: $out"

  # Absent: the MISSING line carries the internal Codebase source, never a public
  # upstream install script, and never the NM_INCOMPATIBLE line.
  rm -f "$fakebin/no-mistakes"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  [ "$out" = "$missing" ] || fail "absent no-mistakes: expected '$missing', got: $out"
  pass "bootstrap detects no-mistakes presence, watch-capability, and internal source"
}

test_bytedcli_required_for_codebase_fleet() {
  local case_dir fakebin out
  # Detection is exercised through a git stub that answers only
  # `git -C <dir> remote get-url origin` from a per-directory .origin-url marker
  # and returns non-zero for every other subcommand. This keeps the test
  # hermetic: it does not depend on live git reads of throwaway repos, which
  # behave differently under CI's non-root, hermetic (GIT_CONFIG_GLOBAL=/dev/null)
  # environment, where the live read came back empty and silently disabled
  # detection. Non-zero for other subcommands leaves the worktree-tangle check
  # inert exactly as a non-git home does. The URL->provider parsing
  # (fm_scm_parse_remote_url) is still exercised for real.

  # Codebase fleet: a registered project clone points at code.byted.org and
  # bytedcli is absent, so bootstrap must surface the missing tool at startup.
  case_dir="$TMP_ROOT/bytedcli-codebase"
  mkdir -p "$case_dir/home/config" "$case_dir/home/projects/foo"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  printf '%s\n' 'https://code.byted.org/obric/foo.git' > "$case_dir/home/projects/foo/.origin-url"
  fakebin=$(make_fake_toolchain "$case_dir")
  add_fake_git_origin_reader "$fakebin"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_BOOTSTRAP_DETECT_ONLY=1 FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  case "$out" in
    *'MISSING: bytedcli (install: NPM_CONFIG_REGISTRY=http://bnpm.byted.org npm install -g @bytedance-dev/bytedcli@latest)'*) ;;
    *) fail "codebase fleet without bytedcli: expected MISSING: bytedcli, got: $out" ;;
  esac

  # GitHub-only fleet: no Codebase remote anywhere, so bytedcli must not appear.
  case_dir="$TMP_ROOT/bytedcli-github"
  mkdir -p "$case_dir/home/config" "$case_dir/home/projects/bar"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  printf '%s\n' 'https://github.com/owner/bar.git' > "$case_dir/home/projects/bar/.origin-url"
  fakebin=$(make_fake_toolchain "$case_dir")
  add_fake_git_origin_reader "$fakebin"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_BOOTSTRAP_DETECT_ONLY=1 FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  case "$out" in
    *bytedcli*) fail "github-only fleet: expected no bytedcli line, got: $out" ;;
  esac
  pass "bootstrap requires bytedcli only for Codebase-provider fleets"
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
  printf '%s\n' '{"rules":[{"when":"fresh news","use":{"harness":"grok"},"why":"current context"},{"when":"big feature","use":[{"harness":"claude","model":"claude-sonnet-5","effort":"high"},{"harness":"codex","model":"gpt-5.5","effort":"high"}]},{"when":"legacy feature","use":[{"harness":"claude"},{"harness":"codex"}],"select":"quota-balanced"}],"default":[{"harness":"pi","model":"anthropic/claude-sonnet-5","effort":"high"},{"harness":"grok","model":"grok-4.5","effort":"high"}]}' > "$case_dir/home/config/crew-dispatch.json"
  fakebin=$(make_fake_toolchain "$case_dir")
  add_real_jq "$fakebin"

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  [ -z "$out" ] || fail "active dispatch profile should be silent by default, got: $out"

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_BOOTSTRAP_VERBOSE_FACTS=1 FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")

  expect=$'BOOTSTRAP_INFO: crew dispatch active config/crew-dispatch.json\nBOOTSTRAP_INFO: crew dispatch rule: fresh news -> grok\nBOOTSTRAP_INFO: crew dispatch rule: big feature -> quota-balanced[claude/claude-sonnet-5/high, codex/gpt-5.5/high]\nBOOTSTRAP_INFO: crew dispatch rule: legacy feature -> quota-balanced[claude, codex]\nBOOTSTRAP_INFO: crew dispatch default: quota-balanced[pi/anthropic/claude-sonnet-5/high, grok/grok-4.5/high]'
  [ "$out" = "$expect" ] || fail "active dispatch verbose info block mismatch"$'\n'"expected: $expect"$'\n'"actual:   $out"
  pass "bootstrap surfaces active crew-dispatch rules only as verbose BOOTSTRAP_INFO"
}

# Orphan-row integrity check: a row under `## In flight` whose state/<id>.meta is
# gone was torn down without its row being closed, and firstmate then re-reports
# landed work as still open (four merged tasks did exactly that). A row WITH a meta
# is ordinary in-flight work and must stay silent.
test_backlog_orphan_rows_are_reported() {
  local case_dir fakebin out
  case_dir="$TMP_ROOT/backlog-orphan"
  mkdir -p "$case_dir/home/config" "$case_dir/home/data" "$case_dir/home/state"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  fakebin=$(make_fake_toolchain "$case_dir")
  cat > "$case_dir/home/data/backlog.md" <<'MD'
# Backlog

## In flight
- [ ] live-task-a1 - still running (repo: alpha) (kind: ship) (since 2026-07-12)
- **bold-orphan-b2** - merged but never closed (repo: beta, since 2026-07-10)
- [ ] orphan-c3 - merged but never closed (repo: gamma) (kind: ship) (since 2026-07-11)
## Queued
- [ ] queued-d4 - not dispatched yet (repo: delta)
## Done
- [x] done-e5 - landed (repo: eps) (done 2026-07-09)
MD
  fm_write_meta "$case_dir/home/state/live-task-a1.meta" \
    "window=fm-live-task-a1" "worktree=$case_dir/wt" "project=$case_dir/project" "kind=ship" "mode=no-mistakes"

  # This case has a state/ dir, so the secondmate sweep runs and greps a non-git
  # home; its git noise is stderr-only and irrelevant to the reported lines.
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)

  printf '%s\n' "$out" | grep -F 'BACKLOG_ORPHAN: orphan-c3 is In flight in data/backlog.md but has no state/orphan-c3.meta' >/dev/null \
    || fail "orphan row with no meta was not reported: $out"
  printf '%s\n' "$out" | grep -F 'BACKLOG_ORPHAN: bold-orphan-b2' >/dev/null \
    || fail "bold-form orphan row was not reported: $out"
  printf '%s\n' "$out" | grep -F 'BACKLOG_ORPHAN: live-task-a1' >/dev/null \
    && fail "in-flight row WITH a meta was falsely reported as an orphan: $out"
  printf '%s\n' "$out" | grep -F 'BACKLOG_ORPHAN: queued-d4' >/dev/null \
    && fail "a Queued row was reported as an In-flight orphan: $out"
  printf '%s\n' "$out" | grep -F 'BACKLOG_ORPHAN: done-e5' >/dev/null \
    && fail "a Done row was reported as an In-flight orphan: $out"
  pass "bootstrap reports In-flight backlog rows whose task meta is gone"
}

# An unmonitored PR is a standing hole, so it has to be re-surfaced rather than
# printed once at arm time. On 2026-07-28 MR 43's failing check reached the
# captain before firstmate, because `watch not armed` had scrolled past inside a
# PR-record run and nothing said it again. Only a task with BOTH a recorded PR
# and a recorded arm failure counts: a PR with a live watch, and a failed arm on
# a task that has no PR yet, are both silent.
test_unwatched_pr_is_reported() {
  local case_dir fakebin out
  case_dir="$TMP_ROOT/nm-unwatched"
  mkdir -p "$case_dir/home/config" "$case_dir/home/data" "$case_dir/home/state"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  fakebin=$(make_fake_toolchain "$case_dir")
  fm_write_meta "$case_dir/home/state/blind-task.meta" \
    "window=fm-blind-task" "worktree=$case_dir/wt" "project=$case_dir/project" \
    "kind=ship" "mode=direct-PR" \
    "pr=https://code.byted.org/o/r/merge_requests/43" \
    "nm_watch_unarmed=repo not initialized (run 'no-mistakes init' first)"
  fm_write_meta "$case_dir/home/state/watched-task.meta" \
    "window=fm-watched-task" "worktree=$case_dir/wt" "project=$case_dir/project" \
    "kind=ship" "mode=direct-PR" \
    "pr=https://code.byted.org/o/r/merge_requests/44" \
    "nm_watch_run=01KWATCHING"
  fm_write_meta "$case_dir/home/state/no-pr-yet.meta" \
    "window=fm-no-pr-yet" "worktree=$case_dir/wt" "project=$case_dir/project" \
    "kind=ship" "mode=direct-PR" \
    "nm_watch_unarmed=no-mistakes is not on PATH"

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)

  printf '%s\n' "$out" | grep -F 'NM_UNWATCHED: blind-task: https://code.byted.org/o/r/merge_requests/43 has no CI monitoring' >/dev/null \
    || fail "a recorded PR with no CI monitoring was not reported: $out"
  printf '%s\n' "$out" | grep -F "repo not initialized" >/dev/null \
    || fail "the report did not carry the reason the watch could not be armed: $out"
  printf '%s\n' "$out" | grep -F 'bin/fm-nm-watch.sh blind-task' >/dev/null \
    || fail "the report gave no re-arm command: $out"
  printf '%s\n' "$out" | grep -F 'NM_UNWATCHED: watched-task' >/dev/null \
    && fail "a PR with a live watch was reported as unmonitored: $out"
  printf '%s\n' "$out" | grep -F 'NM_UNWATCHED: no-pr-yet' >/dev/null \
    && fail "a task with no PR yet was reported as an unmonitored PR: $out"
  pass "bootstrap re-surfaces a recorded PR whose CI watch was never armed"
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
traex xhigh effort is accepted^{"rules":[{"when":"deep investigation","use":{"harness":"traex","effort":"xhigh"}}]}^empty^
unsupported traex max effort is flagged^{"rules":[{"when":"deep work","use":{"harness":"traex","effort":"max"}}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - invalid effort: traex:max
unsupported opencode effort is flagged^{"rules":[{"when":"opencode work","use":{"harness":"opencode","model":"anthropic/claude-sonnet-4-5","effort":"high"}}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - invalid effort: opencode:high
array use with quota-balanced is accepted^{"rules":[{"when":"big feature","use":[{"harness":"claude","model":"claude-sonnet-5","effort":"high"},{"harness":"codex","model":"gpt-5.5","effort":"high"}],"select":"quota-balanced"}]}^empty^
array use without select is accepted^{"rules":[{"when":"big feature","use":[{"harness":"claude"},{"harness":"codex"}]}]}^empty^
one-element array use is accepted^{"rules":[{"when":"focused feature","use":[{"harness":"claude"}]}]}^empty^
default array is accepted^{"default":[{"harness":"pi","model":"anthropic/claude-sonnet-5"},{"harness":"grok"}]}^empty^
one-element default array is accepted^{"default":[{"harness":"codex"}]}^empty^
empty array use is flagged^{"rules":[{"when":"big feature","use":[]}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - each rule needs at least one use profile
array profile without harness is flagged^{"rules":[{"when":"big feature","use":[{"model":"gpt-5.5"}]}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - each use profile needs harness
array profile with malformed model is flagged^{"rules":[{"when":"big feature","use":[{"harness":"codex","model":5}]}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - use profile model and effort must be non-empty strings when present
unknown select is flagged^{"rules":[{"when":"big feature","use":[{"harness":"claude"},{"harness":"codex"}],"select":"mystery"}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - unknown select: mystery
array profile unsupported effort is flagged^{"rules":[{"when":"big feature","use":[{"harness":"codex","effort":"max"}]}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - invalid effort: codex:max
empty launch is flagged^{"rules":[{"when":"gateway work","use":[{"harness":"claude","launch":""}]}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - launch must be a non-empty string
non-string launch is flagged^{"rules":[{"when":"gateway work","use":[{"harness":"claude","launch":3}]}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - launch must be a non-empty string
empty default array is flagged^{"default":[]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - default needs at least one profile
non-object default array entry is flagged^{"default":["codex"]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - each default profile must be an object
default array profile without harness is flagged^{"default":[{"model":"gpt-5.5"}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - each default profile needs harness
default array malformed effort is flagged^{"default":[{"harness":"codex","effort":3}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - default profile model and effort must be non-empty strings when present
ROWS
  pass "bootstrap validates crew-dispatch.json and reports malformed or unverified configs"
}

# Launch variants are the declared, human-selected alternative launch identities
# (a gateway account, a different launcher). Bootstrap must surface which ones a
# home has and reject the shapes that would otherwise only fail at spawn time.
test_harness_overrides_variants_validation() {
  local label body mode expect case_dir fakebin out n
  n=0
  while IFS='^' read -r label body mode expect; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case_dir="$TMP_ROOT/variants-$n"
    mkdir -p "$case_dir/home/config"
    printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
    printf '%s\n' "$body" > "$case_dir/home/config/harness-overrides.json"
    fakebin=$(make_fake_toolchain "$case_dir")
    add_real_jq "$fakebin"
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
      FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
    case "$mode" in
      empty) [ -z "$out" ] || fail "$label: expected silence, got: $out" ;;
      exact) [ "$out" = "$expect" ] || fail "$label: expected '$expect', got: $out" ;;
    esac
  done <<'ROWS'
legacy file without variants stays silent^{"claude":{"command":"cc"}}^empty^
declared variants are surfaced^{"claude":{"command":"cc","variants":{"gateway":{"command":"/opt/claude-gw"},"subscription":{}}}}^exact^HARNESS_OVERRIDES: claude launch variants: gateway, subscription
the default variant is marked^{"claude":{"default_variant":"gateway","variants":{"gateway":{},"subscription":{}}}}^exact^HARNESS_OVERRIDES: claude launch variants: gateway (default), subscription
non-object variants is flagged^{"claude":{"variants":"gateway"}}^exact^HARNESS_OVERRIDES: invalid config/harness-overrides.json - variants must be an object
non-object variant entry is flagged^{"claude":{"variants":{"gateway":"cc"}}}^exact^HARNESS_OVERRIDES: invalid config/harness-overrides.json - each variant must be an object
undeclared default_variant is flagged^{"claude":{"default_variant":"gone","variants":{"gateway":{}}}}^exact^HARNESS_OVERRIDES: invalid config/harness-overrides.json - default_variant names a variant that is not declared: claude.gone
default_variant with no variants is flagged^{"claude":{"default_variant":"gateway"}}^exact^HARNESS_OVERRIDES: invalid config/harness-overrides.json - default_variant names a variant that is not declared: claude.gateway
bad command inside a variant is flagged^{"claude":{"variants":{"gateway":{"command":7}}}}^exact^HARNESS_OVERRIDES: invalid config/harness-overrides.json - command must be a string
bad env inside a variant is flagged^{"claude":{"variants":{"gateway":{"env":{"K":9}}}}}^exact^HARNESS_OVERRIDES: invalid config/harness-overrides.json - env values must be strings
a valid quota source stays silent^{"claude":{"variants":{"gateway":{"quota":{"command":"llm-quota","args":["--json"],"key":"claude_code"}}}}}^exact^HARNESS_OVERRIDES: claude launch variants: gateway
a quota source without a key is flagged^{"claude":{"variants":{"gateway":{"quota":{"command":"llm-quota"}}}}}^exact^HARNESS_OVERRIDES: invalid config/harness-overrides.json - quota needs a non-empty key (claude.gateway)
a harness-level quota beside variants is flagged^{"claude":{"quota":{"command":"llm-quota","key":"k"},"variants":{"gateway":{}}}}^exact^HARNESS_OVERRIDES: invalid config/harness-overrides.json - quota must be declared on each variant, not on claude, which declares variants
ROWS
  pass "bootstrap validates and surfaces harness-overrides launch variants"
}

# crew-dispatch.json and harness-overrides.json are edited independently, so a
# profile pointing at a renamed or deleted variant must be caught at session start
# rather than as a refused spawn hours later.
test_crew_dispatch_launch_cross_file_check() {
  local case_dir fakebin out
  case_dir="$TMP_ROOT/dispatch-launch-xfile"
  mkdir -p "$case_dir/home/config"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  printf '%s\n' '{"rules":[{"when":"overflow work","use":{"harness":"claude","launch":"gateway"}}]}' \
    > "$case_dir/home/config/crew-dispatch.json"
  printf '%s\n' '{"claude":{"variants":{"gateway":{"command":"/opt/claude-gw"}}}}' \
    > "$case_dir/home/config/harness-overrides.json"
  fakebin=$(make_fake_toolchain "$case_dir")
  add_real_jq "$fakebin"

  # The rule listing is a capability fact, so it is verbose-only; the cross-file
  # complaint below stays unconditional because it is a real misconfiguration.
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_BOOTSTRAP_VERBOSE_FACTS=1 FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  printf '%s\n' "$out" | grep -F 'rule: overflow work -> claude launch=gateway' >/dev/null \
    || fail "a declared launch variant should be shown in the active rule listing: $out"
  printf '%s\n' "$out" | grep -F 'undeclared harness variant' >/dev/null \
    && fail "a declared variant must not be reported as undeclared: $out"

  # Now break the link the way a rename would.
  printf '%s\n' '{"claude":{"variants":{"cca":{"command":"/opt/claude-gw"}}}}' \
    > "$case_dir/home/config/harness-overrides.json"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  printf '%s\n' "$out" | grep -F 'CREW_DISPATCH: invalid config/crew-dispatch.json - launch names an undeclared harness variant: claude.gateway' >/dev/null \
    || fail "a dispatch profile naming a missing variant was not reported: $out"
  pass "bootstrap cross-checks dispatch launch names against declared harness variants"
}

test_bootstrap_reporting
test_no_mistakes_present_or_internal_source
test_bytedcli_required_for_codebase_fleet
test_git_is_required_with_supported_install_instruction
test_orca_backend_gates_orca_tool_only_when_selected
test_session_provider_backends_do_not_require_tmux
test_session_provider_backends_gate_own_cli_not_tmux
test_herdr_install_requires_manual_action
test_cmux_bundled_cli_satisfies_dependency
test_unknown_backend_reports_invalid_configuration
test_json_backends_require_jq_not_tmux
test_treehouse_lease_check_follows_resolved_backend
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
test_backlog_orphan_rows_are_reported
test_unwatched_pr_is_reported
test_harness_overrides_variants_validation
test_crew_dispatch_launch_cross_file_check
