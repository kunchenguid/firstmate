#!/usr/bin/env bash
# fm-stopped-lib.sh - the single owner of the DECLARED-STOP record,
# state/<id>.stopped, and of the incarnation binding that keeps it honest.
#
# Why this exists. Supervision has exactly two vocabularies for a quiet
# endpoint: the worker is working, or the worker is broken. It has none for
# "this worker is intentionally not running". So a worker firstmate itself
# stopped through bin/fm-control.sh exit - which preserves the endpoint, the
# local copy, and every uncommitted change on purpose - leaves an agent-free
# endpoint that stale detection reads as a wedge, forever. On 2026-08-25 two
# workers stopped for a four-hour quota reset produced an alert every few
# minutes for the whole window, each one indistinguishable at arrival from the
# alert that reports a genuinely dead worker. That is how a reader learns to
# skim the alert that matters.
#
# The discriminator is NOT the task's backlog hold: a task can be legitimately
# held for a captain decision while its worker is genuinely wedged, and that
# must still surface. The discriminator is whether FIRSTMATE ITSELF stopped the
# agent, which the control plane knows at the moment it acts and which nothing
# downstream could otherwise recover. This record carries exactly that fact.
#
# Record format (v1, one key=value per line, written atomically, mode 0600):
#   v1
#   task=<id>
#   incarnation=<token>    the ONE field that bounds this record's authority
#   reason=<one line>      why firstmate stopped it, and how to resume
#   harness=<name>         evidence, never authority
#   endpoint=<target>      evidence, never authority
#   backend=<name>         evidence, never authority
#   ts=<iso8601>
#   epoch=<unix seconds>
#
# The incarnation binding is the whole safety property. A record applies to the
# ONE agent it was written for, identified by the meta's spawn_gen - the token
# bin/fm-spawn.sh mints fresh on every spawn AND every relaunch. A replacement
# worker on the same task id therefore carries a different token, so a record
# left behind by its predecessor matches nothing and silences nobody. A meta
# with no spawn_gen (a record published before that field existed) falls back to
# a hash of the endpoint identity, the same legacy shape
# bin/fm-inactive-reconcile.sh uses, so an old task is bound rather than
# unbounded.
#
# What this record does NOT do: it never suppresses anything on its own. It
# states a fact. bin/fm-crew-state.sh pairs it with a dead agent before
# reporting `stopped`, and the supervisors absorb only that authoritative
# verdict - so an agent that died on its own, which writes no record, still
# surfaces immediately, and an agent that is alive is never absorbed on a record
# alone.
#
# No side effects on source. set -u / set -e safe.

# fm_stopped_path: the declared-stop record for <id> under <state>.
fm_stopped_path() {  # <state-dir> <id>
  printf '%s/%s.stopped' "$1" "$2"
}

_fm_stopped_meta_get() {  # <meta-file> <key>
  [ -f "$1" ] || return 0
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

_fm_stopped_hash() {  # <text>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print substr($1, 1, 32)}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print substr($1, 1, 32)}'
  else
    printf '%s' "$1" | cksum | awk '{printf "%08x%08x", $1, $2}'
  fi
}

# fm_stopped_incarnation: the token identifying the agent CURRENTLY recorded for
# <id>. Prints nothing when there is no record to identify at all, which is the
# one case no declared stop may match.
fm_stopped_incarnation() {  # <state-dir> <id>
  local meta=$1/$2.meta gen identity
  [ -f "$meta" ] || return 0
  gen=$(_fm_stopped_meta_get "$meta" spawn_gen)
  case "$gen" in
    ''|*[!A-Za-z0-9._-]*) ;;
    *) printf '%s' "$gen"; return 0 ;;
  esac
  identity=$(_fm_stopped_meta_get "$meta" tasktmp)
  [ -n "$identity" ] \
    || identity="$(_fm_stopped_meta_get "$meta" window)|$(_fm_stopped_meta_get "$meta" worktree)"
  [ "$identity" != "|" ] || return 0
  printf 'legacy-%s' "$(_fm_stopped_hash "$identity")"
}

# fm_stopped_field: one field from <id>'s declared-stop record, or nothing.
fm_stopped_field() {  # <state-dir> <id> <key>
  local record
  record=$(fm_stopped_path "$1" "$2")
  [ -f "$record" ] && [ ! -L "$record" ] || return 0
  grep "^$3=" "$record" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# fm_stopped_declared: 0 when <id> carries a declared-stop record that binds to
# the incarnation recorded for it RIGHT NOW. A record whose incarnation no
# longer matches is spent - a relaunch already replaced the agent it described -
# and is reported as not declared, so the replacement is supervised normally.
fm_stopped_declared() {  # <state-dir> <id>
  local recorded current
  recorded=$(fm_stopped_field "$1" "$2" incarnation)
  [ -n "$recorded" ] || return 1
  current=$(fm_stopped_incarnation "$1" "$2")
  [ -n "$current" ] || return 1
  [ "$recorded" = "$current" ]
}

# fm_stopped_age: seconds since the binding record was written, or nothing.
fm_stopped_age() {  # <state-dir> <id>
  local epoch now
  epoch=$(fm_stopped_field "$1" "$2" epoch)
  case "$epoch" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s)
  [ "$now" -ge "$epoch" ] || { printf '0'; return 0; }
  printf '%s' $((now - epoch))
}

# fm_stopped_record: declare that <id>'s endpoint is agent-free BY DESIGN.
# Refuses without a resolvable incarnation, because an unbound record could
# outlive the agent it describes and silence a later, different worker on the
# same task. The reason is collapsed to a single line: the record is read back
# into one-line supervision output.
fm_stopped_record() {  # <state-dir> <id> <reason> [harness] [endpoint] [backend]
  local state=$1 id=$2 reason=$3 harness=${4:-} endpoint=${5:-} backend=${6:-}
  local incarnation record tmp
  incarnation=$(fm_stopped_incarnation "$state" "$id")
  [ -n "$incarnation" ] || return 1
  reason=$(printf '%s' "$reason" | tr '\n\r\t' '   ')
  [ -n "$reason" ] || reason="stopped by firstmate through the control plane"
  record=$(fm_stopped_path "$state" "$id")
  tmp="$record.tmp.$$"
  {
    echo "v1"
    echo "task=$id"
    echo "incarnation=$incarnation"
    echo "reason=$reason"
    echo "harness=$harness"
    echo "endpoint=$endpoint"
    echo "backend=$backend"
    echo "ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "epoch=$(date +%s)"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$record" || { rm -f "$tmp"; return 1; }
}
