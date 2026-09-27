#!/usr/bin/env bash
# Behavior tests for fm-bootstrap.sh reporting and session-start clone refresh bounds.
#
# Bootstrap prints one block or line per actionable problem, optional verbose
# BOOTSTRAP_INFO fact, or completed bootstrap no-action fact and is silent when
# all is well. firstmate consumes the exact 'MISSING: treehouse (install: ...)',
# 'MISSING: tasks-axi (install: ...)', 'MISSING: quota-axi (install: ...)',
# 'MISSING: gh-axi (install: ...)', 'MISSING: lavish-axi (install: ...)', and
# 'BOOTSTRAP_INFO: ...' lines, so those contracts are pinned verbatim. The cases
# are table-driven over the inputs that vary: whether `treehouse get --help`
# advertises --lease, which (if any) tasks-axi version is on PATH, whether
# tasks-axi update advertises --archive-body, whether its mv help advertises
# multi-ID moves, whether quota-axi is on PATH,
# whether the local backend config opts out of tasks-axi backlog mutations,
# which no-mistakes version is on PATH, which gh-axi version is on PATH, and
# which lavish-axi version is on PATH.
# Dedicated fleet-sync cases pin the computed bootstrap timeout, explicit
# override, blank-env defaulting, partial-output relay, and pre-launch timeout
# scan.
# Dedicated network-phase cases pin FM_BOOTSTRAP_NETWORK as a true partition of
# one run into its local and network halves, and the one-hop tasks-axi
# compatibility handoff that keeps a session start from paying for that verdict
# twice.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-bootstrap-tests)
export FM_BACKEND_CMUX_BUNDLE_BIN="$TMP_ROOT/no-bundled-cmux"
# Hermetic inbox-event source. Bootstrap arms the inbox store-event tail
# whenever its watch file exists; the ambient ~/data/inbox/events.jsonl must
# not leak into these cases, so point the watch at a path that never exists.
export INBOX_EVENTS_FILE="$TMP_ROOT/no-inbox-events.jsonl"

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
  fm_fake_exit0 "$fakebin" tmux node chrome-devtools-axi
  fm_fake_version_tool "$fakebin" lavish-axi FM_FAKE_LAVISH_AXI_VERSION 0.1.46
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' "${FM_FAKE_GH_AXI_VERSION:-0.1.29}"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/gh-axi"
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
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' "${FM_FAKE_NO_MISTAKES_VERSION:-no-mistakes version v1.31.2 (fake) 2026-06-27T00:02:18Z}"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  add_tasks_axi "$fakebin" "0.2.4"
  add_quota_axi "$fakebin"
  printf '%s\n' "$fakebin"
}

add_quota_axi() {
  local fakebin=$1
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' "${FM_FAKE_QUOTA_AXI_VERSION:-0.1.17}"
  exit 0
fi
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
treehouse --lease support is accepted silently^1^0.2.4^1^manual^empty^^
treehouse without --lease reports an upgrade, gh auth is fine^0^0.2.4^1^-^grep^MISSING: treehouse (install: curl -fsSL https://kunchenguid.github.io/treehouse/install.sh | sh)^NEEDS_GH_AUTH
compatible tasks-axi is silent by default^1^0.2.4^1^-^empty^^
missing tasks-axi is required by default^1^-^1^-^exact^MISSING: tasks-axi (install: npm install -g tasks-axi)^
incompatible tasks-axi is required by default^1^0.1.0^1^-^exact^MISSING: tasks-axi (install: npm install -g tasks-axi)^
tasks-axi without archive-body is required by default^1^0.2.4:noarchive^1^-^exact^MISSING: tasks-axi (install: npm install -g tasks-axi)^
tasks-axi without multi-id mv is required by default^1^0.2.4:nomulti^1^-^exact^MISSING: tasks-axi (install: npm install -g tasks-axi)^
missing quota-axi is required by default^1^0.2.4^0^manual^exact^MISSING: quota-axi (install: npm install -g quota-axi)^
manual backlog backend still requires missing tasks-axi^1^-^1^manual^exact^MISSING: tasks-axi (install: npm install -g tasks-axi)^
manual backlog backend suppresses tasks-axi availability^1^0.2.4^1^manual^empty^^
ROWS
  pass "bootstrap reports treehouse lease + tasks-axi/quota-axi bootstrap contracts"
}

# beads-authority migration Stage 5 resilience layer (report.md section 5,
# docs/configuration.md "Beads resilience layer"): a beads-store outage only
# reaches MISSING: when no fresh local mirror covers it, and reports DEGRADED:
# naming the mirror's timestamp when one does.
write_beads_mirror_fixture() {
  local home=$1 age_seconds=$2 written_at
  mkdir -p "$home/state"
  written_at=$(($(date +%s) - age_seconds))
  jq -n --argjson written_at "$written_at" --arg output 'ready-task-1' \
    '{written_at: $written_at, output: $output}' > "$home/state/.beads-mirror-ready.json"
}

test_beads_backend_missing_vs_degraded() {
  local case_dir fakebin home out

  # 1. task CLI missing, no mirror -> hard MISSING:
  case_dir="$TMP_ROOT/beads-missing-no-mirror"
  home="$case_dir/home"
  mkdir -p "$home/config"
  printf '%s\n' beads > "$home/config/backlog-backend"
  fakebin=$(make_fake_toolchain "$case_dir")
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_BOOTSTRAP_DETECT_ONLY=1 "$ROOT/bin/fm-bootstrap.sh")
  printf '%s\n' "$out" | grep -Fq 'MISSING: task CLI (beads store; install:' \
    || fail "missing task CLI with no mirror did not report MISSING: $out"

  # 2. task CLI missing, fresh mirror -> DEGRADED:, never MISSING:
  case_dir="$TMP_ROOT/beads-missing-fresh-mirror"
  home="$case_dir/home"
  mkdir -p "$home/config"
  printf '%s\n' beads > "$home/config/backlog-backend"
  write_beads_mirror_fixture "$home" 60
  fakebin=$(make_fake_toolchain "$case_dir")
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_BOOTSTRAP_DETECT_ONLY=1 "$ROOT/bin/fm-bootstrap.sh")
  printf '%s\n' "$out" | grep -Fq 'DEGRADED: task CLI not found (beads store; install:' \
    || fail "missing task CLI with a fresh mirror did not report DEGRADED: $out"
  printf '%s\n' "$out" | grep -Fq 'MISSING: task CLI' \
    && fail "missing task CLI with a fresh mirror still reported MISSING: $out"

  # 3. task CLI present but store unreachable, no mirror -> hard MISSING:
  case_dir="$TMP_ROOT/beads-unreachable-no-mirror"
  home="$case_dir/home"
  mkdir -p "$home/config"
  printf '%s\n' beads > "$home/config/backlog-backend"
  fakebin=$(make_fake_toolchain "$case_dir")
  cat > "$fakebin/task" <<'SH'
#!/usr/bin/env bash
exit 7
SH
  chmod +x "$fakebin/task"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_BOOTSTRAP_DETECT_ONLY=1 "$ROOT/bin/fm-bootstrap.sh")
  printf '%s\n' "$out" | grep -Fq 'MISSING: task store is unreachable or broken (beads backend configured, cannot run '\''task list'\''), and no usable local mirror' \
    || fail "unreachable store with no mirror did not report MISSING: $out"

  # 4. task CLI present but store unreachable, fresh mirror -> DEGRADED:
  case_dir="$TMP_ROOT/beads-unreachable-fresh-mirror"
  home="$case_dir/home"
  mkdir -p "$home/config"
  printf '%s\n' beads > "$home/config/backlog-backend"
  write_beads_mirror_fixture "$home" 60
  fakebin=$(make_fake_toolchain "$case_dir")
  cat > "$fakebin/task" <<'SH'
#!/usr/bin/env bash
exit 7
SH
  chmod +x "$fakebin/task"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_BOOTSTRAP_DETECT_ONLY=1 "$ROOT/bin/fm-bootstrap.sh")
  printf '%s\n' "$out" | grep -Fq "DEGRADED: task store is unreachable or broken (beads backend configured, cannot run 'task list'); using local mirror from" \
    || fail "unreachable store with a fresh mirror did not report DEGRADED: $out"
  printf '%s\n' "$out" | grep -Fq 'MISSING: task store' \
    && fail "unreachable store with a fresh mirror still reported MISSING: $out"

  # 5. task CLI present but store unreachable, mirror older than the freshness
  # threshold -> hard MISSING:, never a stale-mirror DEGRADED:
  case_dir="$TMP_ROOT/beads-unreachable-stale-mirror"
  home="$case_dir/home"
  mkdir -p "$home/config"
  printf '%s\n' beads > "$home/config/backlog-backend"
  write_beads_mirror_fixture "$home" 100000
  fakebin=$(make_fake_toolchain "$case_dir")
  cat > "$fakebin/task" <<'SH'
#!/usr/bin/env bash
exit 7
SH
  chmod +x "$fakebin/task"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_BOOTSTRAP_DETECT_ONLY=1 "$ROOT/bin/fm-bootstrap.sh")
  printf '%s\n' "$out" | grep -Fq 'MISSING: task store is unreachable or broken (beads backend configured, cannot run '\''task list'\''), and no usable local mirror' \
    || fail "unreachable store with a stale mirror did not fall back to MISSING: $out"
  printf '%s\n' "$out" | grep -Fq 'DEGRADED:' \
    && fail "unreachable store with a stale mirror wrongly reported DEGRADED: $out"

  pass "beads backend bootstrap escalates to MISSING: only when both the live store and every local mirror are unusable, else reports DEGRADED: with the mirror timestamp"
}

test_beads_write_queue_reconciled_on_bootstrap() {
  local case_dir home fakebin queue out log
  case_dir="$TMP_ROOT/beads-write-queue-reconcile"
  home="$case_dir/home"
  mkdir -p "$home/config" "$home/state"
  printf '%s\n' beads > "$home/config/backlog-backend"
  queue="$home/state/.beads-write-queue"
  log="$home/task-close.log"
  jq -nc --arg id bd-1 --arg desc 'close: task-1' --argjson epoch "$(date +%s)" \
    '{queued_at: $epoch, task_id: $id, description: $desc, argv: ["close", $id, "--reason", "landed"]}' \
    > "$queue"
  fakebin=$(make_fake_toolchain "$case_dir")
  cat > "$fakebin/task" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "$log"
case "\$*" in
  'list --limit 1') exit 0 ;;
  'close bd-1 --reason landed') exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/task"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  assert_contains "$out" "BEADS_WRITE_QUEUE: reconciled queued write for bd-1" \
    "bootstrap did not replay the durable write queue once the store recovered"
  [ -s "$queue" ] && fail "the write queue was not drained after a successful replay"
  assert_grep "close bd-1 --reason landed" "$log" "the queued close was never replayed against the live store"

  pass "bootstrap reconciles the durable beads write queue against a recovered store, with no separate polling loop"
}

# make_beads_sync_home <case-name> [publisher_rc] [backend]: build a home on the
# beads backend plus a fake `task` whose store answers and reports one approved
# Dolt remote, plus a stub publisher the sweep delegates its remote leg to.
# Prints "<home> <fakebin> <log> <publisher>".
#
# The sweep issues NO client-side Dolt remote command any more, so the fake
# `task` is never the thing that pushes: the publisher stub is, and its own log
# is what the cadence and budget assertions count. That separation is the point
# of the delegation and is exactly what these tests must be able to observe.
# The stub prints <case-dir>/publisher.lines when that file exists, which lets a
# test choose the outcome the sweep relays.
make_beads_sync_home() {
  local case_name=$1 publisher_rc=${2:-0} backend=${3:-beads} case_dir home fakebin log publisher
  case_dir="$TMP_ROOT/$case_name"
  home="$case_dir/home"
  log="$case_dir/task.log"
  mkdir -p "$home/config" "$home/state"
  printf '%s\n' "$backend" > "$home/config/backlog-backend"
  fakebin=$(make_fake_toolchain "$case_dir")
  add_real_jq "$fakebin"
  cat > "$fakebin/task" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "$log"
case "\$*" in
  'list --limit 1') exit 0 ;;
  'dolt remote list --json') printf '%s\n' '[{"name":"mini1"}]'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/task"
  publisher="$case_dir/fm-beads-remote-backup.sh"
  cat > "$publisher" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "$log.publisher"
if [ -f "$case_dir/publisher.lines" ]; then
  cat "$case_dir/publisher.lines"
else
  printf '%s\n' "BEADS_BACKUP: pushed-verified: 'mini1' now shares local main (aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)"
fi
exit $publisher_rc
SH
  chmod +x "$publisher"
  : > "$log"
  : > "$log.publisher"
  printf '%s %s %s %s\n' "$home" "$fakebin" "$log" "$publisher"
}

# count_publisher_calls <publisher-log>: how many times the sweep delegated its
# remote leg to the approved publisher.
count_publisher_calls() {
  grep -c . "$1" 2>/dev/null || true
}

# Test: under the beads backend, the store sync is a routine network-phase sweep
# that pushes this home's commits off the machine, and its own minimum interval
# keeps it from running on every single session start.
test_beads_sync_sweep_runs_and_rate_limits() {
  local home fakebin log publisher out
  read -r home fakebin log publisher <<< "$(make_beads_sync_home beads-sync-runs)"

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_BEADS_SYNC_BACKUP_BIN="$publisher" FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  assert_contains "$out" "BEADS_SYNC: pushed-verified:" \
    "bootstrap did not sync the beads store to its approved remote"
  [ "$(count_publisher_calls "$log.publisher")" = 1 ] \
    || fail "the sync sweep never delegated its remote leg to the approved publisher"
  assert_present "$home/state/.beads-sync-last" \
    "the sync sweep left no stamp, so it would run again on the very next session"

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_BEADS_SYNC_BACKUP_BIN="$publisher" FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  [ "$(count_publisher_calls "$log.publisher")" = 1 ] \
    || fail "the sync sweep ignored its own minimum interval and synced twice in a row"
  assert_not_contains "$out" "BEADS_SYNC:" \
    "a rate-limited sweep still reported a sync it did not run"

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_BEADS_SYNC_BACKUP_BIN="$publisher" FM_BEADS_SYNC_MIN_INTERVAL=0 \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  [ "$(count_publisher_calls "$log.publisher")" = 2 ] \
    || fail "the sync sweep did not run again once its interval had elapsed"
  pass "bootstrap syncs the beads store on a bounded routine interval, not on every session start"
}

# Test: the sweep is config-gated. A home on the tasks-axi backend must be
# byte-for-byte unaffected, even with a task CLI sitting right there on PATH.
test_beads_sync_sweep_is_gated_on_the_beads_backend() {
  local home fakebin log publisher out
  read -r home fakebin log publisher <<< "$(make_beads_sync_home beads-sync-gated 0 tasks-axi)"

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_BEADS_SYNC_BACKUP_BIN="$publisher" FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  assert_not_contains "$out" "BEADS_SYNC:" \
    "a tasks-axi home reported a beads sync it should never run"
  assert_no_grep "dolt" "$log" "a tasks-axi home reached for the Dolt remote"
  [ "$(count_publisher_calls "$log.publisher")" = 0 ] \
    || fail "a tasks-axi home delegated to the approved publisher"
  assert_absent "$home/state/.beads-sync-last" \
    "a tasks-axi home was left beads sync state it does not own"
  pass "the beads store sync never runs on a home that did not select the beads backend"
}

# Test: sync is a network sweep, so the local half of bootstrap - the half
# session start blocks on - never waits for a remote. This is what keeps a slow
# or unreachable remote off the critical path of every session.
test_beads_sync_sweep_stays_off_the_blocking_local_phase() {
  local home fakebin log publisher out
  read -r home fakebin log publisher <<< "$(make_beads_sync_home beads-sync-phase)"

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_BEADS_SYNC_BACKUP_BIN="$publisher" FM_BOOTSTRAP_NETWORK=skip \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  assert_not_contains "$out" "BEADS_SYNC:" "the blocking local phase ran a network sync"
  assert_no_grep "dolt" "$log" "the blocking local phase reached for the Dolt remote"
  [ "$(count_publisher_calls "$log.publisher")" = 0 ] \
    || fail "the blocking local phase delegated to the approved publisher"

  printf '%s\n' 424242 > "$home/state/.lock"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_BEADS_SYNC_BACKUP_BIN="$publisher" FM_BOOTSTRAP_NETWORK=only FM_BOOTSTRAP_NETWORK_LOCK_PID=424242 \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  assert_contains "$out" "BEADS_SYNC: pushed-verified:" \
    "the deferred network phase did not run the store sync"

  printf '%s\n' 999999 > "$home/state/.lock"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_BEADS_SYNC_BACKUP_BIN="$publisher" FM_BEADS_SYNC_MIN_INTERVAL=0 FM_BOOTSTRAP_NETWORK=only FM_BOOTSTRAP_NETWORK_LOCK_PID=424242 \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  assert_contains "$out" "changed before beads store sync" \
    "a stale worker synced the store after the fleet lock had changed hands"
  pass "the beads store sync runs in the deferred network phase, never on session start's blocking path"
}

# Test: a failing remote is a reported diagnostic, never a stall. Bootstrap still
# succeeds, and the attempt is stamped so a broken remote backs off instead of
# being retried by every session that starts.
test_beads_sync_sweep_failure_is_reported_not_fatal() {
  local home fakebin log publisher out rc
  read -r home fakebin log publisher <<< "$(make_beads_sync_home beads-sync-fails 1)"
  printf '%s\n' "BEADS_BACKUP: push-failed: 'dolt_push' to 'mini1' failed: transport down" \
    > "$(dirname "$publisher")/publisher.lines"

  # This file runs under `set -u` alone, never errexit, so the status is captured
  # with `|| rc=$?` rather than by toggling `set -e` around the call. Toggling it
  # ON here would leave errexit enabled for every test defined after this one,
  # and the first later command that legitimately exits non-zero would kill the
  # run mid-file with no failure message.
  rc=0
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_BEADS_SYNC_BACKUP_BIN="$publisher" FM_FAKE_TREEHOUSE_LEASE_HELP=1 \
    "$ROOT/bin/fm-bootstrap.sh") || rc=$?
  expect_code 0 "$rc" "a failing beads sync failed the whole bootstrap run"
  assert_contains "$out" "BEADS_SYNC: push-failed: 'dolt_push' to 'mini1' failed" \
    "a failing sync was swallowed instead of reported as a diagnostic"
  assert_present "$home/state/.beads-sync-last" \
    "a failing sync left no stamp, so every session would retry the broken remote"
  pass "a failing beads sync is a reported diagnostic that never wedges or fails bootstrap"
}

# Test: a store that does not answer already has an owner - the local phase
# reports it as MISSING or DEGRADED against the mirror it fell back to. Syncing
# against it can accomplish nothing and would only re-report the same outage in
# a second, more alarming vocabulary pointed at the wrong cause. The cadence
# stamp must stay unwritten too, so sync resumes on the first session after the
# store recovers instead of waiting out the whole interval.
test_beads_sync_sweep_skips_an_unreachable_store() {
  local home fakebin log publisher out
  read -r home fakebin log publisher <<< "$(make_beads_sync_home beads-sync-unreachable)"
  cat > "$fakebin/task" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_TASK_LOG"
exit 1
SH
  chmod +x "$fakebin/task"

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_BEADS_SYNC_BACKUP_BIN="$publisher" FM_FAKE_TASK_LOG="$log" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  assert_not_contains "$out" "BEADS_SYNC:" \
    "a known store outage was re-reported a second time as a sync diagnostic"
  assert_no_grep "dolt" "$log" "the sweep reached for the Dolt remote over a store that does not answer"
  [ "$(count_publisher_calls "$log.publisher")" = 0 ] \
    || fail "the sweep delegated to the approved publisher over a store that does not answer"
  assert_absent "$home/state/.beads-sync-last" \
    "an unreachable store burned the cadence window, delaying sync past the recovery"
  pass "the beads sync sweep skips a store outage that the local phase already owns"
}

# Test: sync runs LAST among the deferred network sweeps and takes only a slice
# of their shared budget. It is the one sweep whose remote nobody has confirmed
# is reachable, so running it first, or letting the remote leg take the whole
# per-step bound, would let a blackholed remote starve the sweeps that keep the
# fleet running.
test_beads_sync_sweep_runs_last_and_within_a_slice_of_the_stage_budget() {
  local home fakebin log publisher out timing started elapsed
  read -r home fakebin log publisher <<< "$(make_beads_sync_home beads-sync-budget)"
  timing="$home/timing.log"

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_BEADS_SYNC_BACKUP_BIN="$publisher" FM_TIMING_LOG="$timing" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  assert_contains "$out" "BEADS_SYNC: pushed-verified:" "the sweep did not run at all"
  [ "$(grep -c 'phase' "$timing")" -gt 1 ] || fail "bootstrap recorded no phase timings to order"
  [ "$(grep -n 'beads-sync' "$timing" | cut -d: -f1)" \
    -gt "$(grep -n 'fleet-sync' "$timing" | cut -d: -f1)" ] \
    || fail "the beads sync ran before the project clone refresh it must not starve"

  # A hanging PUBLISHER proves the sweep's own budget comes from the stage
  # budget: a third of 12s is 4s, well under the 45s per-step bound left at its
  # default. The timeout is generous so bootstrap startup overhead on a loaded CI
  # runner does not exhaust the budget before the remote leg is reached.
  cat > "$publisher" <<'SH'
#!/usr/bin/env bash
sleep 30
exit 0
SH
  chmod +x "$publisher"
  started=$(date +%s)
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_BEADS_SYNC_BACKUP_BIN="$publisher" FM_FAKE_TASK_LOG="$log" \
    FM_BEADS_SYNC_MIN_INTERVAL=0 FM_STARTUP_NETWORK_TIMEOUT=12 \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  elapsed=$(( $(date +%s) - started ))
  assert_contains "$out" "BEADS_SYNC: remote leg failed: timed out after" \
    "the sweep did not take its bound from the network stage's own budget"
  [ "$elapsed" -lt 20 ] \
    || fail "the sweep held the network stage for ${elapsed}s against a 12s stage budget"
  pass "the beads sync sweep runs last and bounds itself to a slice of the network stage budget"
}

# Test: the sweep's budget starts before its FIRST command, not before the remote
# leg it names. The store-reachability read runs ahead of every bounded step, so
# a Dolt server that accepts the connection and then never answers would hold the
# whole deferred network stage on a probe nobody bounded - starving the
# secondmate, handoff, and clone-refresh sweeps that share that stage's budget.
test_beads_sync_sweep_bounds_its_reachability_probe() {
  local home fakebin log publisher out started elapsed
  read -r home fakebin log publisher <<< "$(make_beads_sync_home beads-sync-probe)"
  cat > "$fakebin/task" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_TASK_LOG"
case "$*" in
  'list --limit 1') sleep 30; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/task"
  printf '%s\n' 424242 > "$home/state/.lock"

  started=$(date +%s)
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_BEADS_SYNC_BACKUP_BIN="$publisher" FM_FAKE_TASK_LOG="$log" FM_STARTUP_NETWORK_TIMEOUT=3 \
    FM_BOOTSTRAP_NETWORK=only FM_BOOTSTRAP_NETWORK_LOCK_PID=424242 \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -lt 15 ] \
    || fail "the sweep hung ${elapsed}s on its reachability probe against a 3s stage budget"
  assert_grep 'list --limit 1' "$log" \
    "the sweep never ran the reachability probe this case exists to bound"
  assert_no_grep "dolt" "$log" "the sweep synced against a store that never answered its probe"
  [ "$(count_publisher_calls "$log.publisher")" = 0 ] \
    || fail "the sweep delegated to the approved publisher after a probe that never answered"
  assert_not_contains "$out" "BEADS_SYNC:" \
    "a store that never answered was reported as a sync outcome"
  assert_absent "$home/state/.beads-sync-last" \
    "a store that never answered burned the cadence window, delaying sync past the recovery"
  pass "the beads sync sweep bounds the reachability probe that precedes its remote leg"
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

test_gh_axi_min_version() {
  local label version mode case_dir fakebin out missing n
  missing='MISSING: gh-axi (install: npm install -g gh-axi && gh-axi setup hooks)'
  n=0
  while IFS='^' read -r label version mode; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case_dir="$TMP_ROOT/gh-axi-$n"
    mkdir -p "$case_dir/home/config"
    printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
    fakebin=$(make_fake_toolchain "$case_dir")
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
      FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_FAKE_GH_AXI_VERSION="$version" "$ROOT/bin/fm-bootstrap.sh")
    case "$mode" in
      empty)
        [ -z "$out" ] || fail "$label: expected silence, got: $out" ;;
      missing)
        [ "$out" = "$missing" ] || fail "$label: expected '$missing', got: $out" ;;
    esac
  done <<'ROWS'
minimum gh-axi version is accepted^0.1.29^empty
newer gh-axi patch is accepted^0.1.30^empty
newer gh-axi minor is accepted^0.2.0^empty
newer gh-axi major is accepted^1.0.0^empty
older gh-axi patch reports an upgrade^0.1.19^missing
much older gh-axi minor reports an upgrade^0.0.9^missing
unparseable gh-axi version reports an upgrade^gh-axi development build^missing
ROWS
  pass "bootstrap enforces gh-axi minimum version"
}

test_lavish_axi_min_version() {
  local label version mode case_dir fakebin out missing n
  missing='MISSING: lavish-axi (install: npm install -g lavish-axi && lavish-axi setup hooks)'
  n=0
  while IFS='^' read -r label version mode; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case_dir="$TMP_ROOT/lavish-axi-$n"
    mkdir -p "$case_dir/home/config"
    printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
    fakebin=$(make_fake_toolchain "$case_dir")
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
      FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_FAKE_LAVISH_AXI_VERSION="$version" "$ROOT/bin/fm-bootstrap.sh")
    case "$mode" in
      empty)
        [ -z "$out" ] || fail "$label: expected silence, got: $out" ;;
      missing)
        [ "$out" = "$missing" ] || fail "$label: expected '$missing', got: $out" ;;
    esac
  done <<'ROWS'
minimum lavish-axi version is accepted^0.1.46^empty
newer lavish-axi patch is accepted^0.1.47^empty
newer lavish-axi minor is accepted^0.2.0^empty
newer lavish-axi major is accepted^1.0.0^empty
the patch just below the floor reports an upgrade^0.1.45^missing
much older lavish-axi minor reports an upgrade^0.0.9^missing
unparseable lavish-axi version reports an upgrade^lavish-axi development build^missing
ROWS
  pass "bootstrap enforces lavish-axi minimum version"
}

test_tasks_axi_min_version() {
  local label version mode case_dir fakebin out missing n archive_body multi_id
  missing='MISSING: tasks-axi (install: npm install -g tasks-axi)'
  n=0
  while IFS='^' read -r label version mode; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case_dir="$TMP_ROOT/tasks-axi-$n"
    mkdir -p "$case_dir/home/config"
    printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
    fakebin=$(make_fake_toolchain "$case_dir")
    archive_body=yes
    multi_id=yes
    case "$version" in
      *:noarchive)
        archive_body=no
        version=${version%:noarchive}
        ;;
    esac
    case "$version" in
      *:nomulti)
        multi_id=no
        version=${version%:nomulti}
        ;;
    esac
    add_tasks_axi "$fakebin" "$version" "$archive_body" "$multi_id"
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
      FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
    case "$mode" in
      empty)
        [ -z "$out" ] || fail "$label: expected silence, got: $out" ;;
      missing)
        [ "$out" = "$missing" ] || fail "$label: expected '$missing', got: $out" ;;
    esac
  done <<'ROWS'
minimum tasks-axi version is accepted^0.2.4^empty
newer tasks-axi patch is accepted^0.2.5^empty
newer tasks-axi minor is accepted^0.3.0^empty
newer tasks-axi major is accepted^1.0.0^empty
older tasks-axi with features reports an upgrade^0.1.1^missing
the patch just below the floor reports an upgrade^0.2.3^missing
unparseable tasks-axi version reports an upgrade^tasks-axi development build^missing
tasks-axi at floor without archive-body reports an upgrade^0.2.4:noarchive^missing
tasks-axi at floor without multi-id reports an upgrade^0.2.4:nomulti^missing
ROWS
  pass "bootstrap enforces tasks-axi minimum version"
}

# These rows exercise the real bootstrap check with a fake quota-axi answering
# --version: below the floor produces MISSING, while at or above is silent.
test_quota_axi_min_version() {
  local label version mode case_dir fakebin out missing n
  missing='MISSING: quota-axi (install: npm install -g quota-axi)'
  n=0
  while IFS='^' read -r label version mode; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case_dir="$TMP_ROOT/quota-axi-$n"
    mkdir -p "$case_dir/home/config"
    printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
    fakebin=$(make_fake_toolchain "$case_dir")
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
      FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_FAKE_QUOTA_AXI_VERSION="$version" "$ROOT/bin/fm-bootstrap.sh")
    case "$mode" in
      empty)
        [ -z "$out" ] || fail "$label: expected silence, got: $out" ;;
      missing)
        [ "$out" = "$missing" ] || fail "$label: expected '$missing', got: $out" ;;
    esac
  done <<'ROWS'
minimum quota-axi version is accepted^0.1.17^empty
newer quota-axi patch is accepted^0.1.18^empty
newer quota-axi minor is accepted^0.2.0^empty
newer quota-axi major is accepted^1.0.0^empty
the patch just below the floor reports an upgrade^0.1.16^missing
much older quota-axi minor reports an upgrade^0.0.9^missing
unparseable quota-axi version reports an upgrade^quota-axi development build^missing
ROWS
  pass "bootstrap enforces quota-axi minimum version"
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
    printf '%s\n' 'config/startup-memory-budget'
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
case "${1:-}" in
  display-message)
    case "$*" in
      *'#{cursor_y}'*) printf '%s\n' 0 ;;
      *) printf '%s\n' codex ;;
    esac
    ;;
  capture-pane) printf '\n' ;;
  list-windows) printf '%s\n' fm-sm ;;
esac
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

# FM_BOOTSTRAP_NETWORK splits one bootstrap run into its local and network
# halves so a session start can compose its digest from the local half alone and
# run the network half concurrently. The property that has to hold is that the
# split is a PARTITION: `skip` plus `only` together do exactly what `all` does,
# with no step dropped and no step run twice.
test_network_phase_partitions_the_run() {
  local case_dir fakebin all_out skip_out only_out combined
  case_dir="$TMP_ROOT/network-phase"
  mkdir -p "$case_dir/home/config"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  fakebin=$(make_fake_toolchain "$case_dir")
  # Break the two diagnostics that stand for the two halves: a local tool floor
  # and the network GitHub-auth probe.
  rm -f "$fakebin/node"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/gh"

  all_out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  assert_contains "$all_out" "MISSING: node (install:" "the unsplit run lost its local diagnostic"
  assert_contains "$all_out" "NEEDS_GH_AUTH" "the unsplit run lost its network diagnostic"

  skip_out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_BOOTSTRAP_NETWORK=skip "$ROOT/bin/fm-bootstrap.sh")
  assert_contains "$skip_out" "MISSING: node (install:" "the local half lost its own diagnostic"
  assert_not_contains "$skip_out" "NEEDS_GH_AUTH" "the local half still made a network call"

  # The deferred network-only worker is always spawned with the lock PID it
  # started under (bin/fm-startup-network.sh) so its mutating sweeps can confirm
  # they still own the fleet lock before touching shared state; model that here
  # so the sweeps run rather than skipping loudly as an unauthorized stale worker.
  mkdir -p "$case_dir/home/state"
  printf '%s\n' 424242 > "$case_dir/home/state/.lock"
  only_out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_BOOTSTRAP_NETWORK=only FM_BOOTSTRAP_NETWORK_LOCK_PID=424242 \
    "$ROOT/bin/fm-bootstrap.sh")
  assert_contains "$only_out" "NEEDS_GH_AUTH" "the network half lost its own diagnostic"
  assert_not_contains "$only_out" "MISSING: node" "the network half repeated the local half's work"

  combined=$(printf '%s\n%s\n' "$skip_out" "$only_out" | LC_ALL=C sort)
  [ "$combined" = "$(printf '%s\n' "$all_out" | LC_ALL=C sort)" ] \
    || fail "skip + only is not the same set of findings as an unsplit run"$'\n'"all:      $all_out"$'\n'"skip:     $skip_out"$'\n'"only:     $only_out"

  # A typo must never silently drop a safety sweep, so anything unrecognized
  # resolves to the complete run.
  [ "$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_BOOTSTRAP_NETWORK=sikp "$ROOT/bin/fm-bootstrap.sh")" = "$all_out" ] \
    || fail "an unrecognized FM_BOOTSTRAP_NETWORK value did not fall back to the complete run"
  pass "bootstrap: FM_BOOTSTRAP_NETWORK partitions one run into local and network halves"
}

test_network_sweeps_recheck_lock_ownership() {
  local case_dir fakebin fake_root marker out
  case_dir="$TMP_ROOT/network-lock-handoff"
  mkdir -p "$case_dir/home/config" "$case_dir/home/projects" "$case_dir/home/state"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  printf '222222\n' > "$case_dir/home/state/.lock"
  fakebin=$(make_fake_toolchain "$case_dir")
  fake_root="$case_dir/root"
  marker="$case_dir/fleet-sync.started"
  mkdir -p "$fake_root/bin"
  cat > "$fake_root/bin/fm-fleet-sync.sh" <<'SH'
#!/usr/bin/env bash
: > "${FM_FAKE_FLEET_SYNC_STARTED_MARKER:?}"
SH
  chmod +x "$fake_root/bin/fm-fleet-sync.sh"

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$fake_root" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_BOOTSTRAP_NETWORK=only \
    FM_BOOTSTRAP_NETWORK_LOCK_PID=111111 FM_FAKE_FLEET_SYNC_STARTED_MARKER="$marker" \
    "$ROOT/bin/fm-bootstrap.sh")
  assert_absent "$marker" "a stale worker refreshed project clones after lock handoff"
  assert_contains "$out" "changed before dead-secondmate relaunch" \
    "the stale worker did not report the refused liveness sweep"
  assert_contains "$out" "changed before secondmate convergence" \
    "the stale worker did not report the refused convergence sweep"
  assert_contains "$out" "changed before pending handoff delivery" \
    "the stale worker did not report the refused handoff sweep"
  assert_contains "$out" "changed before project clone refresh" \
    "the stale worker did not report the refused clone refresh"
  pass "bootstrap: every deferred mutating sweep rechecks fleet-lock ownership"
}

# The verdict costs three subprocesses, so a caller that already has it can hand
# it over - but only one hop, and never onward into a spawned agent's
# environment, where it could outlive a tasks-axi upgrade.
# assert_timing_record <log> <scope> <name> <detail> <msg>: one bin/fm-timing-lib.sh
# record with exactly these fields must exist. Field-exact rather than a substring
# match, so a detail that landed in the wrong column cannot pass.
assert_timing_record() {
  local log=$1 scope=$2 name=$3 detail=$4 msg=$5
  awk -F'\t' -v s="$scope" -v n="$name" -v d="$detail" '
    $1 == "v1" && $2 == s && $3 == n && $6 == d { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$log" || fail "$msg"$'\n'"$(cat "$log")"
}

# The deferred network stage publishes ONE started/finished pair, so a slow run
# used to be unattributable without re-running it by hand. These are the records
# that make it attributable, and they must come from the real sweeps rather than
# a stand-in: what is being pinned is that each network owner is actually wrapped.
# bin/fm-timing-lib.sh stays inert unless FM_TIMING_LOG names a file, so an
# ordinary bootstrap run is unaffected either way, which is asserted here too.
test_network_phases_record_per_step_elapsed_times() {
  local case_dir fakebin log fields
  case_dir="$TMP_ROOT/network-timings"
  mkdir -p "$case_dir/home/config" "$case_dir/home/state" "$case_dir/home/data" "$case_dir/home/projects"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  printf '%s\n' $$ > "$case_dir/home/state/.lock"
  fakebin=$(make_fake_toolchain "$case_dir")
  # A real clone with a real origin, so fm-fleet-sync.sh genuinely iterates it.
  fm_git_init_commit "$case_dir/home/projects/alpha"
  fm_git_add_origin "$case_dir/home/projects/alpha" "$case_dir/alpha-origin"
  # A secondmate the liveness sweep must account for. Whatever verdict it reaches
  # is owned elsewhere; what matters here is that the step is measured.
  fm_write_secondmate_meta "$case_dir/home/state/mate-a.meta" "$case_dir/home"

  log="$case_dir/timings.tsv"
  PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_BOOTSTRAP_NETWORK=only \
    FM_BOOTSTRAP_NETWORK_LOCK_PID=$$ FM_TIMING_LOG="$log" FM_TIMING_EPOCH_MS=0 \
    "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1

  assert_present "$log" "the network phase recorded no elapsed times at all"
  assert_timing_record "$log" phase gh-auth '' "the GitHub auth probe was not timed"
  assert_timing_record "$log" phase secondmate-liveness '' "the dead-secondmate relaunch sweep was not timed"
  assert_timing_record "$log" phase secondmate-sync '' "the secondmate convergence sweep was not timed"
  assert_timing_record "$log" phase handoff-delivery '' "the pending handoff sweep was not timed"
  assert_timing_record "$log" phase fleet-sync '' "the project clone refresh was not timed"
  assert_timing_record "$log" secondmate liveness mate-a \
    "the liveness sweep was not attributed to the individual secondmate it checked"
  assert_timing_record "$log" clone sync alpha \
    "the clone refresh was not attributed to the individual clone it refreshed"

  # Every record carries a start offset and an elapsed time, both numeric, so the
  # artifact can be read as a timeline rather than a bag of durations.
  fields=$(awk -F'\t' '$4 ~ /^[0-9]+$/ && $5 ~ /^[0-9]+$/ { n++ } END { print n+0 }' "$log")
  [ "$fields" = "$(grep -c . "$log")" ] \
    || fail "some records lack a numeric start offset and elapsed time: $(cat "$log")"

  # And an ordinary run - the local half, or any caller that never asked for
  # timings - writes nothing anywhere.
  rm -f "$log"
  PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_BOOTSTRAP_NETWORK=only \
    FM_BOOTSTRAP_NETWORK_LOCK_PID=$$ \
    "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
  assert_absent "$log" "a run that never asked for timings recorded them anyway"
  pass "bootstrap: each deferred network phase, secondmate, and clone records its own elapsed time"
}

test_tasks_axi_verdict_handoff_is_consumed_once() {
  local case_dir fakebin log out
  case_dir="$TMP_ROOT/tasks-axi-handoff"
  mkdir -p "$case_dir/home/config"
  fakebin=$(make_fake_toolchain "$case_dir")
  log="$case_dir/tasks-axi.log"
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_TASKS_AXI_LOG:?}"
printf '0.0.1\n'
exit 0
SH
  chmod +x "$fakebin/tasks-axi"

  # Without the handoff, the incompatible stub is probed and reported.
  : > "$log"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TASKS_AXI_LOG="$log" FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  assert_contains "$out" "MISSING: tasks-axi (install:" "the unaided run did not probe tasks-axi"
  assert_grep '--version' "$log" "the unaided run never ran the probe"

  # With it, the probe is skipped entirely and the handed-in verdict is used.
  : > "$log"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TASKS_AXI_LOG="$log" FM_FAKE_TREEHOUSE_LEASE_HELP=1 \
    FM_TASKS_AXI_COMPATIBLE=1 "$ROOT/bin/fm-bootstrap.sh")
  assert_not_contains "$out" "MISSING: tasks-axi" "the handed-in verdict was ignored"
  [ ! -s "$log" ] || fail "the handed-in verdict did not save the probe: $(cat "$log")"

  # A malformed value is not a verdict.
  : > "$log"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TASKS_AXI_LOG="$log" FM_FAKE_TREEHOUSE_LEASE_HELP=1 \
    FM_TASKS_AXI_COMPATIBLE=yes "$ROOT/bin/fm-bootstrap.sh")
  assert_contains "$out" "MISSING: tasks-axi (install:" "a malformed handoff value was trusted"

  # And the handoff never reaches a grandchild: bootstrap spawns agents, and a
  # verdict cached into an agent's environment would outlive the tool it describes.
  out=$(FM_TASKS_AXI_COMPATIBLE=1 bash -c '. "$1"; printf "%s\n" "${FM_TASKS_AXI_COMPATIBLE-unset}"' \
    _ "$ROOT/bin/fm-tasks-axi-lib.sh")
  [ "$out" = unset ] || fail "sourcing the library left the handoff in the environment: $out"
  pass "bootstrap: the tasks-axi compatibility verdict travels exactly one process hop"
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
pi-signed max effort is accepted^{"rules":[{"when":"signed coding","use":{"harness":"pi-signed","model":"openai-codex/gpt-5.6-sol","effort":"max"}}]}^empty^
muse shared efforts are accepted^{"rules":[{"when":"muse low","use":{"harness":"muse","effort":"low"}},{"when":"muse medium","use":{"harness":"muse","effort":"medium"}},{"when":"muse high","use":{"harness":"muse","effort":"high"}},{"when":"muse xhigh","use":{"harness":"muse","effort":"xhigh"}},{"when":"muse max","use":{"harness":"muse","effort":"max"}}]}^empty^
unsupported muse ultra effort is flagged^{"rules":[{"when":"muse ultra","use":{"harness":"muse","effort":"ultra"}}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - invalid effort: muse:ultra
unsupported opencode effort is flagged^{"rules":[{"when":"opencode work","use":{"harness":"opencode","model":"anthropic/claude-sonnet-4-5","effort":"high"}}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - invalid effort: opencode:high
kimi model profile is accepted^{"rules":[{"when":"kimi work","use":{"harness":"kimi","model":"kimi-code/k3"}}]}^empty^
unsupported kimi effort is flagged^{"rules":[{"when":"kimi work","use":{"harness":"kimi","model":"kimi-code/k3","effort":"high"}}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - invalid effort: kimi:high
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
empty default array is flagged^{"default":[]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - default needs at least one profile
non-object default array entry is flagged^{"default":["codex"]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - each default profile must be an object
default array profile without harness is flagged^{"default":[{"model":"gpt-5.5"}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - each default profile needs harness
default array malformed effort is flagged^{"default":[{"harness":"codex","effort":3}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - default profile model and effort must be non-empty strings when present
ROWS
  pass "bootstrap validates crew-dispatch.json and reports malformed or unverified configs"
}

test_bootstrap_reporting
test_beads_backend_missing_vs_degraded
test_beads_write_queue_reconciled_on_bootstrap
test_beads_sync_sweep_runs_and_rate_limits
test_beads_sync_sweep_is_gated_on_the_beads_backend
test_beads_sync_sweep_stays_off_the_blocking_local_phase
test_beads_sync_sweep_failure_is_reported_not_fatal
test_beads_sync_sweep_skips_an_unreachable_store
test_beads_sync_sweep_runs_last_and_within_a_slice_of_the_stage_budget
test_beads_sync_sweep_bounds_its_reachability_probe
test_no_mistakes_min_version
test_gh_axi_min_version
test_lavish_axi_min_version
test_tasks_axi_min_version
test_quota_axi_min_version
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
test_network_phase_partitions_the_run
test_network_sweeps_recheck_lock_ownership
test_network_phases_record_per_step_elapsed_times
test_tasks_axi_verdict_handoff_is_consumed_once
test_crew_dispatch_active_rules_are_verbose_bootstrap_info
test_crew_dispatch_validation
