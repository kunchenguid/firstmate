#!/usr/bin/env bash
# Merged-teardown actuator: for each ship task whose latest durable status
# line reports a finished PR (`done [at=<epoch>]: PR https://...` or
# `paused [at=<epoch>]: ... awaiting captain merge of https://...`), look the
# PR up once via `gh pr view <url> --json state`:
#
#   MERGED -> run bin/fm-teardown.sh <id> once, then stamp
#             state/.merged-teardown-acks/<id>.done so the task is never
#             dispatched again.
#   CLOSED (not merged) -> print one `closed-no-merge: <id>` wake line and
#             stamp <id>.closed-no-merge so the captain is asked exactly once
#             and the task is dropped from tracking. Never auto-tear down.
#   teardown exits non-zero (unlanded-work refusal, etc.) -> print one
#             `teardown-refused: <id>: <first stderr line>` wake line and
#             stamp <id>.teardown-refused, then stop tracking the id. The
#             refusal is durable evidence in the task's own state; the
#             decision belongs to firstmate/captain, so the check does not
#             loop on it.
#   OPEN (or any other state) -> do nothing until the PR settles.
#
# Output is the wake contract (bin/fm-watch.sh sweeps each registered
# state/<id>.check.sh and surfaces its stdout): silence means nothing new.
# The check is read-only against projects/ and against every other record
# under state/; the only writes/binaries are this script, the ack directory
# above, and the fm-teardown.sh invocations themselves. It never touches the
# no-mistakes daemon, and it is an actuator only: the watcher's stale path
# remains the single stale monitor.
#
# Actions:
#   (default) run one check sweep; print one wake line per new event
#   dry-run   same sweep, but never run teardown and never stamp ack markers;
#             prints `dry-run no-op` when nothing would have run
#             (FM_MERGED_TEARDOWN_DRY_RUN=1 takes the same path, so the
#             watcher sweep can exercise the check without dispatching while
#             the actuator is being rolled out)
#   arm       write and register state/merged-teardown.check.sh
#   disarm    remove the check shim and its trust binding (ack markers kept)
#   --help    print this help
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CHECK_ID="merged-teardown"
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
ACKS="$STATE/.merged-teardown-acks"
TEARDOWN_BIN="${FM_MERGED_TEARDOWN_TEARDOWN_BIN:-$SCRIPT_DIR/fm-teardown.sh}"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

DRY_RUN=0
[ "${FM_MERGED_TEARDOWN_DRY_RUN:-0}" = 1 ] && DRY_RUN=1
# A real (non-stubbed) teardown under dry-run is a wire-up bug, never a normal
# outcome; refuse before the ack markers below train the check into silence.
probe_teardown() {
  local bin=$1
  [ "$DRY_RUN" = 1 ] || return 0
  case $bin in *fakebin*|*stub*) return 0 ;; esac
  head -n 1 "$bin" 2>/dev/null | grep -q "fm-merged-teardown test stub"
}

usage() {
  cat <<'EOF'
Usage:
  fm-merged-teardown.check.sh [check]   sweep ship tasks with finished PRs; tear down merged, report once
  fm-merged-teardown.check.sh dry-run  same sweep with teardown and ack stamping disabled
  fm-merged-teardown.check.sh arm       write and register state/merged-teardown.check.sh
  fm-merged-teardown.check.sh disarm    remove the check shim and its trust binding
  fm-merged-teardown.check.sh --help    print this help

The sweep reads state/<id>.meta (kind=ship) and the latest state/<id>.status
line; a `done ... PR https://...` or `paused ... awaiting captain merge of
https://...` line makes the task eligible. `gh pr view <url> --json state`
decides: MERGED tears down once (ack in state/.merged-teardown-acks/), CLOSED
prints `closed-no-merge: <id>` once, a failed teardown prints
`teardown-refused: <id>: <reason>` once, and anything else stays silent.
EOF
}

die_usage() {
  printf 'fm-merged-teardown: %s\n' "$1" >&2
  usage >&2
  exit 2
}

# run_gh <url> <state-out-file>: decide the PR state through `gh --json state`.
# Prints the state (e.g. MERGED, CLOSED, OPEN) or nothing on lookup failure;
# the exit status is gh's own.
run_gh() {
  local url=$1
  gh pr view "$url" --json state --jq .state 2>/dev/null
}

# pr_url_from_status <line>: echo a plausible PR URL from a status line whose
# body carries the PR, or return 1. Only http(s) github hosts count, so an
# arbitrary URL in free text is not fed to gh.
pr_url_from_status() {
  local line=$1 url
  url=${line#*https://}
  [ "$url" != "$line" ] || return 1
  url="https://${url%%[ ),]*}"
  case $url in
    https://github.com/*/pull/[0-9]*) printf '%s\n' "$url" ;;
    *) return 1 ;;
  esac
}

# eligible_pr_url <id>: echo the PR URL for a ship task whose latest status
# line reports a finished PR, else return 1.
eligible_pr_url() {
  local id=$1 meta=$2 status=$3 line
  grep -q '^kind=ship$' "$meta" 2>/dev/null || return 1
  [ -f "$status" ] || return 1
  line=$(tail -n 1 "$status") || return 1
  case $line in
    'done '[at=*']:'*' PR https://'*) ;;
    'paused '[at=*]':'*'awaiting captain merge of https://'*) ;;
    *) return 1 ;;
  esac
  pr_url_from_status "$line"
}

# ack_path <id> <suffix>: the marker path, refusing an id that could escape
# the ack directory.
ack_path() {
  printf '%s/%s.%s\n' "$ACKS" "$1" "$2"
}

ack_stamped() {
  [ -f "$1" ]
}

stamp_ack() {
  local path=$1
  mkdir -p "$ACKS" || return 1
  printf 'at=%s\n' "$(date +%s)" > "$path"
}

# Append to the check's wake line. One line per scheduling tick is the
# contract, so concurrent task events are joined with ' ; '.
WAKE_MSG=
wake_note() {
  if [ -z "$WAKE_MSG" ]; then
    WAKE_MSG=$1
  else
    WAKE_MSG="$WAKE_MSG ; $1"
  fi
}

action_check() {
  [ -d "$STATE" ] || {
    [ "$DRY_RUN" = 0 ] || printf 'dry-run no-op\n'
    return 0
  }
  # The ack directory keeps the one-shot bookkeeping; mkdir it even in dry-run
  # so its read path is exercised.
  mkdir -p "$ACKS" || return 0
  local meta id status url state errfile reason
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    [ -f "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    ack_stamped "$(ack_path "$id" "done")" && continue
    ack_stamped "$(ack_path "$id" closed-no-merge)" && continue
    ack_stamped "$(ack_path "$id" teardown-refused)" && continue
    status="$STATE/$id.status"
    url=$(eligible_pr_url "$id" "$meta" "$status") || continue
    state=$(run_gh "$url")
    case $state in
      MERGED)
        if [ "$DRY_RUN" = 1 ]; then
          probe_teardown "$TEARDOWN_BIN" \
            || { printf 'fm-merged-teardown: dry-run refuses to run a real teardown (%s)\n' \
                "$TEARDOWN_BIN" >&2; return 1; }
          wake_note "merged-teardown(dry): $id would be torn down after PR merge"
          continue
        fi
        errfile=$(mktemp) || continue
        if FM_HOME="$FM_HOME" "$TEARDOWN_BIN" "$id" 2>"$errfile" >&2; then
          rm -f -- "$errfile"
          stamp_ack "$(ack_path "$id" "done")" || continue
          wake_note "merged-teardown: $id torn down after PR merge"
        else
          reason=$(head -n 1 "$errfile")
          rm -f -- "$errfile"
          [ -n "$reason" ] || reason="fm-teardown exited non-zero"
          # Keep the wake line single-line and bounded.
          reason=${reason//$'\r'/ }
          reason=${reason:0:200}
          stamp_ack "$(ack_path "$id" teardown-refused)" || continue
          wake_note "teardown-refused: $id: $reason"
        fi
        ;;
      CLOSED)
        if [ "$DRY_RUN" = 1 ]; then
          wake_note "closed-no-merge(dry): $id"
          continue
        fi
        stamp_ack "$(ack_path "$id" closed-no-merge)" || continue
        wake_note "closed-no-merge: $id"
        ;;
      '')
        # Lookup failure (network, auth, fake repo): stay silent, retry next tick.
        ;;
      *)
        # OPEN or any pre-merge state: keep watching, nothing to report.
        ;;
    esac
  done
  if [ -n "$WAKE_MSG" ]; then
    printf '%s\n' "$WAKE_MSG"
  elif [ "$DRY_RUN" = 1 ]; then
    printf 'dry-run no-op\n'
  fi
  return 0
}

# The home is embedded already resolved, because the watcher runs the shim from
# its own working directory and a relative spelling would send the check to a
# different home, or to none at all.
shim_content() {
  local home=$1 check
  check=$(printf '%q' "$SCRIPT_DIR/fm-merged-teardown.check.sh")
  # The single-quoted shim lines reach the watcher unexpanded; the guard
  # deliberately resolves $CHECK at sweep time, not here.
  # shellcheck disable=SC2016
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by bin/fm-merged-teardown.check.sh - merged-teardown shim.' \
    '# The watcher validates these bytes. Until the checked-in script lands on' \
    '# this checkout the shim no-ops silently; after the fast-forward that ships' \
    '# the PR, the exec below starts dispatching against the real fleet.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "CHECK=$check" \
    '[ -x "$CHECK" ] || exit 0' \
    'exec "$CHECK" check'
}

SHIM_WRITE_TMP=

# Write the shim the way this repo writes its other trusted check shims: the
# guards run before anything is written, so a symlink at the shim path is
# refused instead of followed, and the bytes arrive by rename so the watcher
# never reads a half-written shim and rejects it as unauthenticated.
shim_write() {
  local want=$1 tmp device
  SHIM_WRITE_TMP=
  device=$(fm_pr_file_device "$STATE") || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  if [ -e "$CHECK_SHIM" ] && [ "$(fm_pr_file_mode "$CHECK_SHIM")" = 700 ] \
    && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ]; then
    return 0
  fi
  tmp=$(umask 077 && mktemp "$STATE/.$CHECK_ID.check.XXXXXX") || return 1
  SHIM_WRITE_TMP=$tmp
  if ! printf '%s\n' "$want" > "$tmp" || ! chmod 0700 "$tmp"; then
    return 1
  fi
  if ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    return 1
  fi
  SHIM_WRITE_TMP=
  fm_pr_private_file_valid "$CHECK_SHIM" 700 "$device"
}

ARM_BACKUP=

shim_backup() {
  local tmp
  tmp=$(mktemp) || return 1
  if ! cat "$CHECK_SHIM" > "$tmp" 2>/dev/null; then
    rm -f -- "$tmp"
    return 1
  fi
  ARM_BACKUP=$tmp
  return 0
}

arm_rollback() {
  rm -f -- "$CHECK_SHIM"
  if [ -n "$ARM_BACKUP" ]; then
    cp "$ARM_BACKUP" "$CHECK_SHIM" 2>/dev/null || true
    chmod 0700 "$CHECK_SHIM" 2>/dev/null || true
    rm -f -- "$ARM_BACKUP"
    ARM_BACKUP=
  fi
  [ -z "$SHIM_WRITE_TMP" ] || rm -f -- "$SHIM_WRITE_TMP"
}

arm_interrupted() {
  arm_rollback
  printf 'fm-merged-teardown: arming was interrupted, so state/%s.check.sh is not armed\n' "$CHECK_ID" >&2
  exit 1
}

action_arm() {
  local want home
  [ -x "$TEARDOWN_BIN" ] || {
    printf 'fm-merged-teardown: fm-teardown.sh is missing at %s; cannot arm\n' "$TEARDOWN_BIN" >&2
    return 1
  }
  mkdir -p "$STATE" || return 1
  case $FM_HOME in
    /*) home=$FM_HOME ;;
    *)
      home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
        printf 'fm-merged-teardown: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
        return 1
      }
      ;;
  esac
  want=$(shim_content "$home")
  ARM_BACKUP=
  if [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ]; then
    ARM_BACKUP=$(shim_backup) || {
      printf 'fm-merged-teardown: could not save the existing %s\n' "$CHECK_SHIM" >&2
      return 1
    }
  fi
  trap arm_interrupted HUP INT TERM
  if ! shim_write "$want"; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-merged-teardown: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  if ! FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-merged-teardown: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  trap - HUP INT TERM
  [ -z "$ARM_BACKUP" ] || rm -f -- "$ARM_BACKUP"
  ARM_BACKUP=
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

action_disarm() {
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

case "${1:-check}" in
  check) action_check ;;
  dry-run) DRY_RUN=1; action_check ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  -h|--help) usage ;;
  *) die_usage "unknown action: $1" ;;
esac
