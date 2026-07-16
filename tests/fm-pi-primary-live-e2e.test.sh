#!/usr/bin/env bash
# Opt-in clean-stock Pi watcher lifecycle regression on an isolated tmux socket.
set -u

scan_lab_processes() {
  local lab=$1 root_pid=${2:-} root_identity=${3:-} snapshot
  snapshot=$(LC_ALL=C ps -axo pid=,ppid=,pgid=,sess=,stat=,lstart=,command= 2>/dev/null) || return 1
  printf '%s\n' "$snapshot" | awk -v lab="$lab" -v root="$root_pid" -v expected="$root_identity" '
    $5 !~ /^Z/ {
      order[++count] = $1
      parent[$1] = $2
      line[$1] = $0
      identity = $2 " " $3 " " $4
      for (field = 6; field <= NF; field += 1) identity = identity " " $field
      if (($1 == root && identity == expected) || (index($0, lab) && $0 ~ /(^|[ \/])(pi|pi-coding-agent|fm-watch(-arm)?[.]sh)([ \/]|$)/)) owned[$1] = 1
    }
    END {
      do {
        changed = 0
        for (i = 1; i <= count; i += 1) {
          pid = order[i]
          if (!owned[pid] && owned[parent[pid]]) {
            owned[pid] = 1
            changed = 1
          }
        }
      } while (changed)
      for (i = 1; i <= count; i += 1) if (owned[order[i]]) print line[order[i]]
    }
  '
}

process_identity() {
  LC_ALL=C ps -o ppid=,pgid=,sess=,lstart=,command= -p "$1" 2>/dev/null | awk '{$1 = $1; print}'
}

validated_pane_identity() {
  local tmux=$1 socket=$2 session=$3 pid=$4 candidate pane
  candidate=$(process_identity "$pid")
  [ -n "$candidate" ] || return 1
  pane=$("$tmux" -L "$socket" display-message -p -t "$session" '#{pane_dead} #{pane_pid}' 2>/dev/null) || return 1
  [ "$pane" = "0 $pid" ] || return 1
  printf '%s\n' "$candidate"
}

wait_for_pi_pane_identity() {
  local tmux=$1 socket=$2 session=$3 pid=$4 initial=$5 attempts=${6:-100}
  local initial_prefix candidate candidate_prefix candidate_command i=0
  initial_prefix=$(printf '%s\n' "$initial" | awk '
    NF >= 9 {
      prefix = $1
      for (field = 2; field <= 8; field += 1) prefix = prefix " " $field
      print prefix
    }
  ')
  [ -n "$initial_prefix" ] || return 1
  while [ "$i" -lt "$attempts" ]; do
    candidate=$(validated_pane_identity "$tmux" "$socket" "$session" "$pid") || return 1
    candidate_prefix=$(printf '%s\n' "$candidate" | awk '
      NF >= 9 {
        prefix = $1
        for (field = 2; field <= 8; field += 1) prefix = prefix " " $field
        print prefix
      }
    ')
    [ "$candidate_prefix" = "$initial_prefix" ] || return 1
    candidate_command=$(printf '%s\n' "$candidate" | awk '
      NF >= 9 {
        command = $9
        for (field = 10; field <= NF; field += 1) command = command " " $field
        print command
      }
    ')
    if [ "$candidate_command" = pi ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

tracked_processes() {
  printf '%s\n' "$1" | awk '
    NF >= 11 {
      identity = $2 " " $3 " " $4
      for (field = 6; field <= NF; field += 1) identity = identity " " $field
      print $1 " " identity
    }
  '
}

tracked_process_alive() {
  local pid=$1 expected=$2 record stat current
  record=$(LC_ALL=C ps -o stat=,ppid=,pgid=,sess=,lstart=,command= -p "$pid" 2>/dev/null | awk '{$1 = $1; print}')
  if [ -z "$record" ]; then
    kill -0 "$pid" 2>/dev/null && return 2
    return 1
  fi
  stat=${record%% *}
  [ "${stat#Z}" = "$stat" ] || return 1
  current=${record#* }
  [ "$current" = "$expected" ] || [ "${current#* }" = "${expected#* }" ]
}

live_tracked_processes() {
  local tracked=$1 pid identity status=0 rc
  while read -r pid identity; do
    [ -n "$pid" ] || continue
    tracked_process_alive "$pid" "$identity"
    rc=$?
    if [ "$rc" -eq 0 ]; then
      printf '%s %s\n' "$pid" "$identity"
    elif [ "$rc" -eq 2 ]; then
      status=1
    fi
  done <<EOF
$tracked
EOF
  return "$status"
}

wait_for_tracked_processes_gone() {
  local tracked=$1 attempts=${2:-50} i=0 live
  while [ "$i" -lt "$attempts" ]; do
    live=$(live_tracked_processes "$tracked") || return 1
    [ -z "$live" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

signal_tracked_processes() {
  local tracked=$1 signal=$2 pid identity status=0 rc
  while read -r pid identity; do
    [ -n "$pid" ] || continue
    tracked_process_alive "$pid" "$identity"
    rc=$?
    if [ "$rc" -eq 0 ]; then
      kill -"$signal" "$pid" 2>/dev/null || status=1
    elif [ "$rc" -eq 2 ]; then
      status=1
    fi
  done <<EOF
$tracked
EOF
  return "$status"
}

terminate_scanned_processes() {
  local lab=$1 attempts=${2:-50} root_pid=${3:-} root_identity=${4:-} snapshot tracked
  snapshot=$(scan_lab_processes "$lab" "$root_pid" "$root_identity") || return 1
  [ -n "$snapshot" ] || return 0
  tracked=$(tracked_processes "$snapshot")
  [ -n "$tracked" ] || return 0
  signal_tracked_processes "$tracked" TERM || return 1
  wait_for_tracked_processes_gone "$tracked" "$attempts" && return 0
  signal_tracked_processes "$tracked" KILL || return 1
  wait_for_tracked_processes_gone "$tracked" "$attempts"
}

finish_lab_cleanup() {
  local lab=$1 cleanup_failed=$2
  rm -f "$lab/pi-agent/auth.json" || return 1
  [ "$cleanup_failed" -eq 0 ] || return 1
  rm -rf "$lab"
}

if [ "${1:-}" = --process-scan-self-test ]; then
  scan_lab=$(mktemp -d "${TMPDIR:-/tmp}/fm-pi-live-scan.XXXXXX")
  cleanup_scan_probes() {
    local pid
    for pid in "${scan_pid_one:-}" "${scan_pid_two:-}" "${scan_pid_root:-}" "${scan_pid_child:-}" "${protected_pid:-}"; do
      [ -n "$pid" ] && kill -KILL "$pid" 2>/dev/null || true
    done
    for pid in "${scan_pid_one:-}" "${scan_pid_two:-}" "${scan_pid_root:-}" "${protected_pid:-}"; do
      [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
    done
    rm -rf "$scan_lab"
  }
  trap cleanup_scan_probes EXIT
  bash -c 'trap "exit 0" TERM; while :; do sleep 1; done' "$scan_lab/fm-watch-arm.sh" >/dev/null 2>&1 &
  scan_pid_one=$!
  bash -c 'trap "exit 0" TERM; while :; do sleep 1; done' "$scan_lab/fm-watch.sh" >/dev/null 2>&1 &
  scan_pid_two=$!
  sleep 300 &
  protected_pid=$!
  perl -e '$0 = "pi"; $SIG{TERM} = sub { exit 0 }; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { $SIG{TERM} = "IGNORE"; sleep 1 while 1 } wait' >/dev/null 2>&1 &
  scan_pid_root=$!
  scan_pid_child=
  for _ in $(seq 1 20); do
    scan_root_identity=$(process_identity "$scan_pid_root")
    scan_pid_child=$(ps -axo pid=,ppid= | awk -v root="$scan_pid_root" '$2 == root { print $1; exit }')
    case "$scan_root_identity" in
      *" pi") [ -n "$scan_pid_child" ] && break ;;
    esac
    sleep 0.05
  done
  sleep 0.1
  owned_row=$(LC_ALL=C ps -axo pid=,ppid=,pgid=,sess=,stat=,lstart=,command= | awk -v owned="$scan_pid_one" -v protected="$protected_pid" \
    '$1 == owned { $1 = protected; print; exit }')
  forged_tracked=$(tracked_processes "$owned_row")
  signal_tracked_processes "$forged_tracked" TERM
  for _ in $(seq 1 20); do
    kill -0 "$protected_pid" 2>/dev/null || break
    sleep 0.05
  done
  if ! kill -0 "$protected_pid" 2>/dev/null; then
    printf 'not ok - Pi live cleanup re-authorized a reused PID after its ownership snapshot\n' >&2
    exit 1
  fi
  mkdir -p "$scan_lab/failing-bin"
  printf '#!/bin/sh\nexit 19\n' > "$scan_lab/failing-bin/ps"
  chmod +x "$scan_lab/failing-bin/ps"
  owned_tracked=$(tracked_processes "$(scan_lab_processes "$scan_lab" "$scan_pid_root" "$scan_root_identity" | awk -v pid="$scan_pid_one" '$1 == pid')")
  if PATH="$scan_lab/failing-bin:$PATH" signal_tracked_processes "$owned_tracked" TERM; then
    printf 'not ok - Pi live cleanup accepted an unavailable identity for a live tracked PID\n' >&2
    exit 1
  fi
  if ! kill -0 "$scan_pid_one" 2>/dev/null; then
    printf 'not ok - Pi live cleanup signaled a live tracked PID without verifying its identity\n' >&2
    exit 1
  fi
  mkdir -p "$scan_lab/identity-bin"
  identity_marker="$scan_lab/identity-captured"
  pane_state="$scan_lab/pane-state"
  cat > "$scan_lab/identity-bin/ps" <<EOF
#!/bin/sh
: > "$identity_marker"
printf '%s\n' '1 2 3 Mon Jul 13 12:00:00 2026 pi'
EOF
  cat > "$scan_lab/identity-bin/tmux" <<EOF
#!/bin/sh
[ -f "$identity_marker" ] || exit 17
cat "$pane_state"
EOF
  chmod +x "$scan_lab/identity-bin/ps" "$scan_lab/identity-bin/tmux"
  printf '1 %s\n' "$scan_pid_root" > "$pane_state"
  retained_identity='launch-identity'
  if refreshed_identity=$(PATH="$scan_lab/identity-bin:$PATH" validated_pane_identity \
      "$scan_lab/identity-bin/tmux" scan-socket scan-session "$scan_pid_root"); then
    retained_identity=$refreshed_identity
  fi
  if [ "$retained_identity" != launch-identity ] || [ ! -f "$identity_marker" ]; then
    printf 'not ok - Pi live cleanup replaced launch identity after pane ownership was lost\n' >&2
    exit 1
  fi
  printf '0 %s\n' "$protected_pid" > "$pane_state"
  if PATH="$scan_lab/identity-bin:$PATH" validated_pane_identity \
      "$scan_lab/identity-bin/tmux" scan-socket scan-session "$scan_pid_root" >/dev/null; then
    printf 'not ok - Pi live cleanup accepted a replacement pane PID\n' >&2
    exit 1
  fi
  printf '0 %s\n' "$scan_pid_root" > "$pane_state"
  refreshed_identity=$(PATH="$scan_lab/identity-bin:$PATH" validated_pane_identity \
    "$scan_lab/identity-bin/tmux" scan-socket scan-session "$scan_pid_root") || {
    printf 'not ok - Pi live cleanup rejected the still-live launch pane\n' >&2
    exit 1
  }
  if [ "$refreshed_identity" != '1 2 3 Mon Jul 13 12:00:00 2026 pi' ]; then
    printf 'not ok - Pi live cleanup returned the wrong validated identity\n' >&2
    exit 1
  fi
  identity_count="$scan_lab/identity-count"
  cat > "$scan_lab/identity-bin/ps" <<EOF
#!/bin/sh
count=0
[ ! -f "$identity_count" ] || count=\$(cat "$identity_count")
count=\$((count + 1))
printf '%s\n' "\$count" > "$identity_count"
if [ "\$count" -le 2 ]; then
  printf '%s\n' '1 2 3 Mon Jul 13 12:00:00 2026 env PI_CODING_AGENT_DIR=/tmp pi'
else
  printf '%s\n' '1 2 3 Mon Jul 13 12:00:00 2026 pi'
fi
EOF
  cat > "$scan_lab/identity-bin/tmux" <<EOF
#!/bin/sh
count=\$(cat "$identity_count")
if [ "\$count" -gt 3 ]; then
  printf '1 %s\n' "$scan_pid_root"
else
  printf '0 %s\n' "$scan_pid_root"
fi
EOF
  chmod +x "$scan_lab/identity-bin/ps" "$scan_lab/identity-bin/tmux"
  transient_identity=$(PATH="$scan_lab/identity-bin:$PATH" validated_pane_identity \
    "$scan_lab/identity-bin/tmux" scan-socket scan-session "$scan_pid_root") || {
    printf 'not ok - Pi live cleanup rejected the transient launch identity\n' >&2
    exit 1
  }
  case "$transient_identity" in
    *' env PI_CODING_AGENT_DIR=/tmp pi') ;;
    *)
      printf 'not ok - Pi live cleanup did not observe the transient launch identity\n' >&2
      exit 1
      ;;
  esac
  stable_identity=$(PATH="$scan_lab/identity-bin:$PATH" wait_for_pi_pane_identity \
    "$scan_lab/identity-bin/tmux" scan-socket scan-session "$scan_pid_root" "$transient_identity" 3) || {
    printf 'not ok - Pi live cleanup did not capture the first validated post-exec Pi identity\n' >&2
    exit 1
  }
  if [ "$stable_identity" != '1 2 3 Mon Jul 13 12:00:00 2026 pi' ]; then
    printf 'not ok - Pi live cleanup retained a transient launch identity\n' >&2
    exit 1
  fi
  cat > "$scan_lab/identity-bin/ps" <<EOF
#!/bin/sh
printf '%s\n' '1 9 3 Mon Jul 13 12:00:00 2026 pi'
EOF
  cat > "$scan_lab/identity-bin/tmux" <<EOF
#!/bin/sh
printf '0 %s\n' "$scan_pid_root"
EOF
  retained_identity=$transient_identity
  if mismatched_identity=$(PATH="$scan_lab/identity-bin:$PATH" wait_for_pi_pane_identity \
      "$scan_lab/identity-bin/tmux" scan-socket scan-session "$scan_pid_root" "$transient_identity" 2); then
    retained_identity=$mismatched_identity
  fi
  if [ "$retained_identity" != "$transient_identity" ]; then
    printf 'not ok - Pi live cleanup replaced launch authority across a birth-identity mismatch\n' >&2
    exit 1
  fi
  launch_order=$(awk '
    /^initial_identity=[$][(]validated_pane_identity / { print "candidate" }
    /^PI_START_IDENTITY=[$]initial_identity$/ { print "commit" }
    /^post_exec_identity=[$][(]wait_for_pi_pane_identity / { print "post-exec" }
    /^PI_START_IDENTITY=[$]post_exec_identity$/ { print "refresh" }
    /^wait_for_text READY / { print "ready" }
  ' "${BASH_SOURCE[0]}")
  if [ "$launch_order" != "$(printf 'candidate\ncommit\npost-exec\nrefresh\nready')" ]; then
    printf 'not ok - Pi live cleanup did not stabilize launch identity before startup wait\n' >&2
    exit 1
  fi
  if PATH="$scan_lab/failing-bin:$PATH" terminate_scanned_processes "$scan_lab" 3 "$scan_pid_root" "$scan_root_identity"; then
    printf 'not ok - Pi live cleanup treated a failed process scan as clean\n' >&2
    exit 1
  fi
  retention_probe="$scan_lab/retained-evidence"
  mkdir -p "$retention_probe/pi-agent"
  printf 'copied credential\n' > "$retention_probe/pi-agent/auth.json"
  finish_lab_cleanup "$retention_probe" 1
  retention_status=$?
  if [ "$retention_status" -ne 1 ] || [ ! -d "$retention_probe" ]; then
    printf 'not ok - Pi live cleanup deleted evidence after a failed process scan\n' >&2
    exit 1
  fi
  if [ -e "$retention_probe/pi-agent/auth.json" ]; then
    printf 'not ok - Pi live cleanup retained the copied auth credential with failed evidence\n' >&2
    exit 1
  fi
  mismatch_identity="$scan_root_identity mismatched"
  mismatch_lab="$scan_lab/unmatched-root-only"
  mismatch_out=$(scan_lab_processes "$mismatch_lab" "$scan_pid_root" "$mismatch_identity")
  if printf '%s\n' "$mismatch_out" | awk -v root="$scan_pid_root" -v child="$scan_pid_child" \
      '$1 == root || $1 == child { found = 1 } END { exit !found }'; then
    printf 'not ok - Pi live scanner trusted a reused root PID: %s\n' "$mismatch_out" >&2
    exit 1
  fi
  terminate_scanned_processes "$mismatch_lab" 3 "$scan_pid_root" "$mismatch_identity" || {
    printf 'not ok - Pi live cleanup failed while rejecting a reused root PID\n' >&2
    exit 1
  }
  if ! kill -0 "$scan_pid_root" 2>/dev/null || ! kill -0 "$scan_pid_child" 2>/dev/null; then
    printf 'not ok - Pi live cleanup signaled a mismatched root identity\n' >&2
    exit 1
  fi
  scan_out=$(scan_lab_processes "$scan_lab" "$scan_pid_root" "$scan_root_identity")
  scan_child_tracked=$(tracked_processes "$(printf '%s\n' "$scan_out" | awk -v child="$scan_pid_child" '$1 == child')")
  if [ "$(printf '%s\n' "$scan_out" | awk 'NF { count += 1 } END { print count + 0 }')" -lt 4 ] \
    || ! printf '%s\n' "$scan_out" | awk -v one="$scan_pid_one" -v two="$scan_pid_two" \
      -v root="$scan_pid_root" -v child="$scan_pid_child" \
      '$1 == one { first = 1 } $1 == two { second = 1 } $1 == root { primary = 1 } $1 == child { descendant = 1 } END { exit !(first && second && primary && descendant) }'; then
    printf 'not ok - Pi live process scanner returned: %s\n' "$scan_out" >&2
    exit 1
  fi
  terminate_scanned_processes "$scan_lab" 3 "$scan_pid_root" "$scan_root_identity" || {
    printf 'not ok - Pi live cleanup left processes: %s\n' "$(scan_lab_processes "$scan_lab" "$scan_pid_root" "$scan_root_identity")" >&2
    exit 1
  }
  scan_child_identity=${scan_child_tracked#* }
  tracked_process_alive "$scan_pid_child" "$scan_child_identity"
  scan_child_status=$?
  if [ "$scan_child_status" -ne 1 ]; then
    kill -KILL "$scan_pid_child" 2>/dev/null || true
    printf 'not ok - Pi live cleanup lost reparented descendant %s\n' "$scan_pid_child" >&2
    exit 1
  fi
  trap - EXIT
  cleanup_scan_probes
  echo "ok - Pi live cleanup isolates and terminates lab-owned processes"
  exit 0
fi

if [ "${FM_PI_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_PI_LIVE_E2E=1 to run the isolated interactive Pi regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v pi >/dev/null 2>&1 || { echo "not ok - pi is required" >&2; exit 1; }
command -v tmux >/dev/null 2>&1 || { echo "not ok - tmux is required" >&2; exit 1; }
AUTH_FILE=${FM_PI_LIVE_AUTH_FILE:-}
[ -n "$AUTH_FILE" ] && [ -f "$AUTH_FILE" ] || { echo "not ok - set FM_PI_LIVE_AUTH_FILE" >&2; exit 1; }

TMUX=$(command -v tmux)
PI_BIN=$(command -v pi)
SOCKET="fm-pi-live-e2e-$$"
SESSION=pi-live-e2e
EVIDENCE_ROOT=${FM_PI_LIVE_EVIDENCE_ROOT:-${TMPDIR:-/tmp}/no-mistakes-evidence}
mkdir -p "$EVIDENCE_ROOT"
LAB=$(mktemp -d "$EVIDENCE_ROOT/fm-pi-live-e2e.XXXXXX")
PROJECT="$LAB/project"
PI_DIR="$LAB/pi-agent"
ROLE=${FM_PI_LIVE_ROLE:-primary}
MODEL=${FM_PI_LIVE_MODEL:-gpt-5.6-sol}
PROVIDER=${FM_PI_LIVE_PROVIDER:-openai-codex}
THINKING=${FM_PI_LIVE_THINKING:-minimal}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
case "$ROLE" in primary|secondmate) ;; *) fail "FM_PI_LIVE_ROLE must be primary or secondmate" ;; esac

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

capture() { "$TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION" -S -1000 2>/dev/null || true; }
current_lines() { "$TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' || true; }

wait_for_text() {
  local expected=$1 attempts=${2:-120} i=0
  while [ "$i" -lt "$attempts" ]; do
    capture | grep -Fq "$expected" && return 0
    sleep 0.5
    i=$((i + 1))
  done
  capture >&2
  return 1
}

wait_for_text_line() {
  local expected=$1 attempts=${2:-120} i=0
  while [ "$i" -lt "$attempts" ]; do
    current_lines | grep -Fxq "$expected" && return 0
    sleep 0.5
    i=$((i + 1))
  done
  capture >&2
  return 1
}

wait_for_turn_idle() {
  local attempts=${1:-120} i=0
  while [ "$i" -lt "$attempts" ]; do
    current_lines | grep -Fq 'Working...' || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

wait_for_status() {
  local expected=$1 attempts=${2:-120} i=0
  while [ "$i" -lt "$attempts" ]; do
    current_lines | grep -Fxq "$expected" && return 0
    sleep 0.25
    i=$((i + 1))
  done
  current_lines >&2
  return 1
}

wait_for_status_absent() {
  local attempts=${1:-120} i=0 pane_dead
  while [ "$i" -lt "$attempts" ]; do
    pane_dead=$("$TMUX" -L "$SOCKET" display-message -p -t "$SESSION" '#{pane_dead}' 2>/dev/null || true)
    [ "$pane_dead" = 1 ] && return 0
    current_lines | grep -Eq '^(offline|watching|handling wake|attention)$' || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

text_count() { capture | grep -Fo "$1" | wc -l | tr -d ' '; }

wait_for_text_count_after() {
  local expected=$1 previous=$2 attempts=${3:-120} i=0 count
  while [ "$i" -lt "$attempts" ]; do
    count=$(text_count "$expected")
    [ "$count" -gt "$previous" ] && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

wait_pid_dead() {
  local pid=$1 i=0
  while [ "$i" -lt 100 ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

wait_for_live_watcher_pid() {
  local previous=${1:-} attempts=${2:-120} i=0 pid
  while [ "$i" -lt "$attempts" ]; do
    pid=$(sed -n '1p' "$PROJECT/state/.watch.lock/pid" 2>/dev/null || true)
    if printf '%s\n' "$pid" | grep -Eq '^[0-9]+$' \
      && [ "$pid" != "$previous" ] \
      && kill -0 "$pid" 2>/dev/null; then
      printf '%s\n' "$pid"
      return 0
    fi
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}

wait_for_clean_exit() {
  local i=0 state
  while [ "$i" -lt 120 ]; do
    state=$("$TMUX" -L "$SOCKET" display-message -p -t "$SESSION" '#{pane_dead} #{pane_dead_status}' 2>/dev/null || true)
    [ "$state" = '1 0' ] && return 0
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}

send_prompt() {
  "$TMUX" -L "$SOCKET" send-keys -t "$SESSION" -l "$1"
  "$TMUX" -L "$SOCKET" send-keys -t "$SESSION" Enter
}

lab_processes() {
  scan_lab_processes "$LAB" "${PI_PID:-}" "${PI_START_IDENTITY:-}"
}

terminate_lab_processes() {
  terminate_scanned_processes "$LAB" 50 "${PI_PID:-}" "${PI_START_IDENTITY:-}"
}

cleanup() {
  local status=$? survivors cleanup_failed=0
  terminate_lab_processes || { status=1; cleanup_failed=1; }
  "$TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  terminate_lab_processes || { status=1; cleanup_failed=1; }
  if ! finish_lab_cleanup "$LAB" "$cleanup_failed"; then
    survivors=$(lab_processes) || survivors='process scan unavailable'
    printf 'not ok - lab-owned processes survived cleanup; evidence retained at %s\n%s\n' "$LAB" "$survivors" >&2
    status=1
  fi
  trap - EXIT
  exit "$status"
}
trap cleanup EXIT

git clone -q "$ROOT" "$PROJECT"
if ! git -C "$ROOT" diff --quiet HEAD -- .pi bin; then
  git -C "$ROOT" diff --binary HEAD -- .pi bin | git -C "$PROJECT" apply
fi
[ "$ROLE" != secondmate ] || : > "$PROJECT/.fm-secondmate-home"
mkdir -p "$PROJECT/state" "$PROJECT/config" "$PI_DIR"
chmod 700 "$LAB" "$PI_DIR"
cp "$AUTH_FILE" "$PI_DIR/auth.json"
chmod 600 "$PI_DIR/auth.json"
cat > "$PI_DIR/settings.json" <<JSON
{"defaultProvider":"$PROVIDER","defaultModel":"$MODEL","defaultThinkingLevel":"$THINKING","enableInstallTelemetry":false,"packages":[]}
JSON
PI_CODING_AGENT_DIR="$PI_DIR" PI_OFFLINE=1 pi list 2>&1 | grep -Fq 'No packages installed.' \
  || fail "isolated Pi home is not clean stock"

WATCH="$PROJECT/.pi/extensions/fm-primary-pi-watch.ts"
launch="exec env PI_CODING_AGENT_DIR=$(shell_quote "$PI_DIR") FM_HOME=$(shell_quote "$PROJECT") FM_ROOT_OVERRIDE=$(shell_quote "$PROJECT") FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=600 PI_OFFLINE=1 $(shell_quote "$PI_BIN") --approve --offline --no-session --verbose -e $(shell_quote "$WATCH") 'Reply exactly READY.'"
"$TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -c "$PROJECT" "$launch"
"$TMUX" -L "$SOCKET" set-window-option -t "$SESSION" remain-on-exit on
PI_PID=$("$TMUX" -L "$SOCKET" display-message -p -t "$SESSION" '#{pane_pid}')
if ! printf '%s\n' "$PI_PID" | grep -Eq '^[0-9]+$' || ! kill -0 "$PI_PID" 2>/dev/null; then
  fail "Pi launch PID was not live"
fi
initial_identity=$(validated_pane_identity "$TMUX" "$SOCKET" "$SESSION" "$PI_PID") \
  || fail "Pi launch identity was unavailable"
PI_START_IDENTITY=$initial_identity
post_exec_identity=$(wait_for_pi_pane_identity \
  "$TMUX" "$SOCKET" "$SESSION" "$PI_PID" "$PI_START_IDENTITY") \
  || fail "Pi post-exec identity was unavailable"
PI_START_IDENTITY=$post_exec_identity
wait_for_text READY 180 || fail "Pi did not start with the watcher extension"
refreshed_identity=$(wait_for_pi_pane_identity \
  "$TMUX" "$SOCKET" "$SESSION" "$PI_PID" "$PI_START_IDENTITY" 1) \
  || fail "Pi launch identity could not be refreshed safely"
PI_START_IDENTITY=$refreshed_identity
wait_for_status watching 180 || fail "watcher did not auto-arm at session start"
capture | grep -Fq 'Trust project folder?' && fail "--approve produced a trust dialog"

: > "$PROJECT/state/pi-e2e.meta"
watcher_pid=$(wait_for_live_watcher_pid "" 180) || fail "initial live watcher PID did not appear"
arm_pid=$(ps -p "$watcher_pid" -o ppid= | tr -d ' ')
if [ -z "$arm_pid" ] || ! kill -0 "$arm_pid" 2>/dev/null; then
  fail "watcher arm process was not live"
fi
send_prompt 'Reply exactly WAKE-READY now. On the next FIRSTMATE WATCHER WAKE, run bin/fm-wake-drain.sh, do not re-arm, and finish exactly WAKE-HANDLED.'
wait_for_text_line WAKE-READY 180 || fail "Pi did not acknowledge the watcher-wake instruction"
wait_for_turn_idle 180 || fail "Pi did not settle after acknowledging the watcher-wake instruction"
wake_count=$(text_count WAKE-HANDLED)
printf 'done: pi live e2e watcher fire\n' > "$PROJECT/state/pi-e2e.status"
wait_for_text_count_after WAKE-HANDLED "$wake_count" 180 || fail "Pi did not handle the watcher wake"
wait_for_turn_idle 180 || fail "Pi did not settle after handling the watcher wake"
wait_pid_dead "$watcher_pid" || fail "completed watcher survived automatic re-arm"
wait_pid_dead "$arm_pid" || fail "completed arm survived automatic re-arm"
new_watcher_pid=$(wait_for_live_watcher_pid "$watcher_pid" 120) \
  || fail "actionable wake did not auto-arm a replacement watcher"
new_arm_pid=$(ps -p "$new_watcher_pid" -o ppid= | tr -d ' ')
if [ -z "$new_arm_pid" ] || ! kill -0 "$new_arm_pid" 2>/dev/null; then
  fail "replacement watcher arm process was not live"
fi
wait_for_status watching 180 || fail "automatic replacement watcher status was not watching"
watcher_pid=$new_watcher_pid
arm_pid=$new_arm_pid

before_failure=$(capture | grep -Fc 'FIRSTMATE WATCHER WAKE: watcher: FAILED' || true)
"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" -l /reload
"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" Enter
wait_for_status_absent 60 || fail "reload did not clear old status"
wait_for_text 'Reloaded keybindings' 120 || fail "Pi reload did not complete"
wait_for_status watching 120 || fail "reloaded watcher did not auto-arm"
wait_pid_dead "$watcher_pid" || fail "old watcher survived reload"
wait_pid_dead "$arm_pid" || fail "old arm survived reload"
after_failure=$(capture | grep -Fc 'FIRSTMATE WATCHER WAKE: watcher: FAILED' || true)
[ "$after_failure" -eq "$before_failure" ] || fail "reload emitted a false failure wake"

new_watcher_pid=$(wait_for_live_watcher_pid "$watcher_pid" 120) \
  || fail "reloaded live watcher PID did not appear"
new_arm_pid=$(ps -p "$new_watcher_pid" -o ppid= | tr -d ' ')
if [ -z "$new_arm_pid" ] || ! kill -0 "$new_arm_pid" 2>/dev/null; then
  fail "reloaded watcher arm process was not live"
fi

"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" -l /quit
"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" Enter
wait_for_status_absent 60 || fail "quit did not clear watcher status"
wait_for_clean_exit || fail "Pi did not exit cleanly"
wait_pid_dead "$new_watcher_pid" || fail "watcher survived clean Pi exit"
wait_pid_dead "$new_arm_pid" || fail "arm survived clean Pi exit"
orphan=$(lab_processes) || fail "final lab process scan failed"
[ -z "$orphan" ] || fail "owned live lab left a process: $orphan"

printf 'ok - Pi %s watcher lifecycle passed for %s with clean reload and exit\n' "$(pi --version)" "$ROLE"
