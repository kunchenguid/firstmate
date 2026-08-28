#!/usr/bin/env bash
# Human-owned notification transition owner.
#
# A decision, blocker, captain hold, or review-ready result is a durable condition,
# but its notification is an edge.  This library derives one evidence fingerprint
# from the immutable task id, task incarnation, condition identity, and meaningful
# evidence.  Supervisors consult that fingerprint before starting a model turn and
# record it only after the durable wake or away-mode escalation has been published.
# A crash between publication and the record can therefore duplicate one notice;
# it cannot lose the first notice.  No elapsed-time input participates.
#
# Records live under state/human-notifications/.  They are presentation receipts,
# never condition truth: status folds, backlog holds, PR metadata, Bearings, and
# explicit fleet views remain authoritative and visible regardless of a receipt.
# A matching resolved line or captain-hold answer removes the receipt, so reopening
# the same key can notify again.  Task cleanup removes every receipt for that task.
#
# Public functions:
#   fm_human_notify_class <status-line>
#   fm_human_notify_pending <state> <task-id> <status-line>
#   fm_human_notify_record <state> <task-id> <status-line>
#   fm_human_notify_apply_transition <state> <task-id> <status-line>
#   fm_human_notify_resolve_line <state> <task-id> <status-line>
#   fm_human_notify_clear_hold <state> <task-id>
#   fm_human_notify_reopen_blocker <state> <task-id>
#   fm_human_notify_clear_review <state> <task-id>
#   fm_human_notify_pr_evidence_is_red <checks> <conclusion>
#   fm_human_notify_review_current <state> <task-id>
#   fm_human_notify_pr_observation_record <state> <task-id> <state> <head> <checks> <conclusion>
#   fm_human_notify_clear_task <state> <task-id>
#   fm_human_notify_summary <state> <task-id> <status-line>
#   fm_human_notify_procevent_label <state> <source-id> <sequence> [expected-adapter]
#
# Return convention: fm_human_notify_pending returns 0 only for a recognized
# human-owned condition whose current fingerprint has not been recorded, 1 for an
# unchanged recognized condition, and 2 for a line outside this contract.

FM_HUMAN_NOTIFY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-classify-lib.sh
. "$FM_HUMAN_NOTIFY_LIB_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-display-name-lib.sh
. "$FM_HUMAN_NOTIFY_LIB_DIR/fm-display-name-lib.sh"

FM_HUMAN_NOTIFY_SCHEMA=fm-human-notification.v1
FM_HUMAN_NOTIFY_CLASS=
FM_HUMAN_NOTIFY_KEY=
FM_HUMAN_NOTIFY_EVIDENCE=
FM_HUMAN_NOTIFY_FINGERPRINT=
FM_HUMAN_NOTIFY_MARKER=

_fm_human_notify_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    cksum | awk '{print "cksum-" $1 "-" $2}'
  fi
}

_fm_human_notify_safe() {
  printf '%s' "$1" | tr '\t\r\n' '   ' | LC_ALL=C tr -d '\000-\037\177'
}

_fm_human_notify_key() {
  _fm_decision_key "$1" 2>/dev/null || printf 'default'
}

fm_human_notify_procevent_label() {  # <state> <source-id> <sequence> [expected-adapter]
  local state=$1 source=$2 sequence=$3 expected=${4:-} adapter_file adapter label
  case "$source" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  case "$sequence" in ''|*[!0-9]*) return 1 ;; esac
  case "$expected" in *[!a-z0-9-]*) return 1 ;; esac
  adapter_file="$state/procevent-inbox/$source.$sequence.adapter"
  [ -f "$adapter_file" ] && [ ! -L "$adapter_file" ] || return 1
  IFS= read -r adapter < "$adapter_file" || return 1
  case "$adapter" in ''|*[!a-z0-9-]*) return 1 ;; esac
  [ -z "$expected" ] || [ "$adapter" = "$expected" ] || return 1
  case "$adapter" in
    lavish) label='Lavish review' ;;
    remote-reply) label='Remote reply' ;;
    when) label='Condition watch' ;;
    *) label="$(fm_display_name_fallback "$adapter") process" ;;
  esac
  printf '%s' "$label"
}

# Review-ready includes both delivery paths: a PR with green checks and a direct
# PR that is ready for review immediately after opening.  Reports and ordinary
# terminal outcomes remain outside this class.
_fm_human_notify_review_ready() {
  local line=$1 verb note
  verb=$(status_line_verb "$line")
  [ "$verb" = done ] || return 1
  note=$(status_line_note "$line")
  case "$note" in
    *'PR https://'*) return 0 ;;
    *https://*'/pull/'*|*https://*'/-/merge_requests/'*) return 0 ;;
    *'ready in branch'*) return 0 ;;
  esac
  return 1
}

fm_human_notify_class() {  # <status-line>
  local line=$1 verb
  verb=$(status_line_verb "$line")
  case "$verb" in
    needs-decision) printf 'decision'; return 0 ;;
    blocked) printf 'blocker'; return 0 ;;
    captain-held) printf 'captain-hold'; return 0 ;;
    failed) printf 'failure'; return 0 ;;
  esac
  if _fm_human_notify_review_ready "$line"; then
    printf 'review-ready'
    return 0
  fi
  if [ "$verb" = done ]; then
    printf 'result'
    return 0
  fi
  if status_is_captain_relevant "$line"; then
    printf 'legacy-result'
    return 0
  fi
  return 1
}

_fm_human_notify_incarnation() {  # <state> <task>
  local state=$1 task=$2 meta key value out='' ident
  meta="$state/$task.meta"
  if [ -f "$meta" ] && [ ! -L "$meta" ]; then
    for key in busy_gen kind window terminal worktree branch project; do
      value=$(grep "^$key=" "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      [ -z "$value" ] || out="$out$key=$value|"
    done
  fi
  if [ -z "$out" ] && [ -f "$state/$task.status" ] && [ ! -L "$state/$task.status" ]; then
    if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
      ident=$(stat -f '%d:%i' "$state/$task.status" 2>/dev/null || true)
    else
      ident=$(stat -c '%d:%i' "$state/$task.status" 2>/dev/null || true)
    fi
    out="status=$ident|"
  fi
  printf '%s' "$out"
}

_fm_human_notify_derive() {  # <state> <task> <line>
  local state=$1 task=$2 line=$3 class key evidence incarnation material marker_id pr pr_head pr_state pr_checks pr_conclusion
  class=$(fm_human_notify_class "$line") || return 2
  key=$(_fm_human_notify_key "$line")
  evidence=$(status_line_note "$line")
  incarnation=$(_fm_human_notify_incarnation "$state" "$task")
  if [ "$class" = review-ready ] && [ -f "$state/$task.meta" ]; then
    pr=$(grep '^pr=' "$state/$task.meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    pr_head=$(grep '^pr_head=' "$state/$task.meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    if [ -f "$state/$task.pr-observation" ] && [ ! -L "$state/$task.pr-observation" ]; then
      pr_state=$(sed -n 's/^state=//p' "$state/$task.pr-observation" | head -1)
      pr_checks=$(sed -n 's/^checks=//p' "$state/$task.pr-observation" | head -1)
      pr_conclusion=$(sed -n 's/^conclusion=//p' "$state/$task.pr-observation" | head -1)
      pr_head=$(sed -n 's/^head=//p' "$state/$task.pr-observation" | head -1)
    else
      pr_state=
      pr_checks=
      pr_conclusion=
    fi
    evidence="$evidence|pr=$pr|head=$pr_head|state=$pr_state|checks=$pr_checks|conclusion=$pr_conclusion"
    key=ready
  fi
  material="class=$class|task=$task|key=$key|incarnation=$incarnation|evidence=$evidence"
  marker_id=$(printf '%s' "$class|$task|$key" | _fm_human_notify_sha256)
  FM_HUMAN_NOTIFY_CLASS=$class
  FM_HUMAN_NOTIFY_KEY=$key
  FM_HUMAN_NOTIFY_EVIDENCE=$evidence
  FM_HUMAN_NOTIFY_FINGERPRINT=$(printf '%s' "$material" | _fm_human_notify_sha256)
  FM_HUMAN_NOTIFY_MARKER="$state/human-notifications/$marker_id"
}

fm_human_notify_pending() {  # <state> <task> <line>
  local state=$1 task=$2 line=$3 recorded legacy_key legacy
  _fm_human_notify_derive "$state" "$task" "$line" || return $?
  if [ "$FM_HUMAN_NOTIFY_CLASS" = review-ready ]; then
    fm_human_notify_review_current "$state" "$task" || return 1
  fi
  recorded=$(sed -n 's/^fingerprint=//p' "$FM_HUMAN_NOTIFY_MARKER" 2>/dev/null | head -1 || true)
  [ "$recorded" != "$FM_HUMAN_NOTIFY_FINGERPRINT" ] || return 1
  # Adopt either pre-owner supervisor receipt on first read, so an upgrade or
  # restart does not replay evidence already presented by the prior version.
  legacy_key=$(printf '%s' "$task" | tr ':/.' '___')
  for legacy in "$state/.hb-surfaced-$legacy_key" "$state/.subsuper-seen-status-$legacy_key"; do
    if [ "$(cat "$legacy" 2>/dev/null || true)" = "$line" ]; then
      fm_human_notify_record "$state" "$task" "$line" || return 0
      return 1
    fi
  done
  return 0
}

_fm_human_notify_receipt_dir_safe() {  # <state>
  local dir="$1/human-notifications"
  [ ! -e "$dir" ] && [ ! -L "$dir" ] && return 0
  [ -d "$dir" ] && [ ! -L "$dir" ]
}

fm_human_notify_record() {  # <state> <task> <line>
  local state=$1 task=$2 line=$3 dir tmp
  _fm_human_notify_derive "$state" "$task" "$line" || return $?
  dir="$state/human-notifications"
  _fm_human_notify_receipt_dir_safe "$state" || return 1
  (umask 077; mkdir -p "$dir") || return 1
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  tmp=$(umask 077; mktemp "$dir/.notification.XXXXXX") || return 1
  if ! {
    printf 'schema=%s\n' "$FM_HUMAN_NOTIFY_SCHEMA"
    printf 'task=%s\n' "$(_fm_human_notify_safe "$task")"
    printf 'class=%s\n' "$FM_HUMAN_NOTIFY_CLASS"
    printf 'key=%s\n' "$FM_HUMAN_NOTIFY_KEY"
    printf 'fingerprint=%s\n' "$FM_HUMAN_NOTIFY_FINGERPRINT"
  } > "$tmp" || ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$FM_HUMAN_NOTIFY_MARKER"; then
    rm -f -- "$tmp"
    return 1
  fi
}

_fm_human_notify_remove_class_key() {  # <state> <task> <class> <key>
  local state=$1 task=$2 class=$3 key=$4 marker_id
  _fm_human_notify_receipt_dir_safe "$state" || return 1
  marker_id=$(printf '%s' "$class|$task|$key" | _fm_human_notify_sha256)
  rm -f -- "$state/human-notifications/$marker_id"
}

_fm_human_notify_remove_task_class() {  # <state> <task> <class>
  local state=$1 task=$2 class=$3 f recorded_task recorded_class
  _fm_human_notify_receipt_dir_safe "$state" || return 1
  [ -d "$state/human-notifications" ] || return 0
  for f in "$state"/human-notifications/*; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    recorded_task=$(sed -n 's/^task=//p' "$f" 2>/dev/null | head -1 || true)
    recorded_class=$(sed -n 's/^class=//p' "$f" 2>/dev/null | head -1 || true)
    [ "$recorded_task" = "$task" ] && [ "$recorded_class" = "$class" ] && rm -f -- "$f"
  done
  return 0
}

fm_human_notify_resolve_line() {  # <state> <task> <status-line>
  local state=$1 task=$2 line=$3 verb key
  verb=$(status_line_verb "$line")
  [ "$verb" = resolved ] || return 2
  key=$(_fm_human_notify_key "$line")
  _fm_human_notify_remove_class_key "$state" "$task" decision "$key"
  _fm_human_notify_remove_class_key "$state" "$task" blocker "$key"
  _fm_human_notify_remove_class_key "$state" "$task" captain-hold "$key"
}

fm_human_notify_apply_transition() {  # <state> <task> <status-line>
  local state=$1 task=$2 line=$3 verb
  verb=$(status_line_verb "$line")
  case "$verb" in
    resolved)
      fm_human_notify_resolve_line "$state" "$task" "$line"
      ;;
    failed)
      _fm_human_notify_remove_task_class "$state" "$task" result
      _fm_human_notify_remove_task_class "$state" "$task" review-ready
      _fm_human_notify_remove_task_class "$state" "$task" legacy-result
      ;;
    done)
      _fm_human_notify_remove_task_class "$state" "$task" failure
      _fm_human_notify_remove_task_class "$state" "$task" legacy-result
      ;;
    working)
      _fm_human_notify_remove_class_key "$state" "$task" blocker default
      _fm_human_notify_remove_task_class "$state" "$task" failure
      _fm_human_notify_remove_task_class "$state" "$task" result
      _fm_human_notify_remove_task_class "$state" "$task" review-ready
      _fm_human_notify_remove_task_class "$state" "$task" legacy-result
      ;;
    needs-decision|blocked|captain-held)
      _fm_human_notify_remove_task_class "$state" "$task" failure
      _fm_human_notify_remove_task_class "$state" "$task" result
      _fm_human_notify_remove_task_class "$state" "$task" review-ready
      _fm_human_notify_remove_task_class "$state" "$task" legacy-result
      ;;
    paused)
      _fm_human_notify_remove_task_class "$state" "$task" failure
      _fm_human_notify_remove_task_class "$state" "$task" result
      _fm_human_notify_remove_task_class "$state" "$task" review-ready
      ;;
  esac
}

fm_human_notify_clear_hold() {  # <state> <captain-held-task-id>
  _fm_human_notify_remove_class_key "$1" "$2" captain-hold "$2"
}

fm_human_notify_reopen_blocker() {  # <state> <task-id>
  local state=$1 task=$2 legacy_key
  _fm_human_notify_remove_task_class "$state" "$task" blocker
  legacy_key=$(printf '%s' "$task" | tr ':/.' '___')
  rm -f -- "$state/.hb-surfaced-$legacy_key" "$state/.subsuper-seen-status-$legacy_key"
}

fm_human_notify_clear_review() {  # <state> <task-id>
  _fm_human_notify_remove_class_key "$1" "$2" review-ready ready
}

fm_human_notify_pr_evidence_is_red() {  # <checks> <conclusion>
  case ",$(printf '%s,%s' "$1" "$2" | tr '[:lower:]' '[:upper:]')," in
    *,FAILURE,*|*,FAILED,*|*,ERROR,*|*,CANCELLED,*|*,CANCELED,*|*,TIMED_OUT,*|*,ACTION_REQUIRED,*|*,STARTUP_FAILURE,*) return 0 ;;
  esac
  return 1
}

fm_human_notify_review_current() {  # <state> <task-id>
  local file state checks conclusion
  file="$1/$2.pr-observation"
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  state=$(sed -n 's/^state=//p' "$file" | head -1)
  checks=$(sed -n 's/^checks=//p' "$file" | head -1)
  conclusion=$(sed -n 's/^conclusion=//p' "$file" | head -1)
  case "$state" in CLOSED|closed|MERGED|merged) return 1 ;; esac
  fm_human_notify_pr_evidence_is_red "$checks" "$conclusion" && return 1
  return 0
}

fm_human_notify_pr_observation_record() {  # <state> <task> <pr-state> <head> <checks> <conclusion>
  local state=$1 task=$2 pr_state=$3 head=$4 checks=$5 conclusion=$6 path tmp pr identity incarnation
  case "$task" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  case "$pr_state" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
  [ -z "$head" ] || [[ "$head" =~ ^[0-9a-f]{40}$|^[0-9a-f]{64}$ ]] || return 1
  case "$checks$conclusion" in *[!A-Za-z0-9_,.-]*) return 1 ;; esac
  path="$state/$task.pr-observation"
  [ ! -L "$path" ] || return 1
  pr=$(grep '^pr=' "$state/$task.meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  identity=$(printf '%s' "$pr" | _fm_human_notify_sha256)
  incarnation=$(printf '%s' "$(_fm_human_notify_incarnation "$state" "$task")" | _fm_human_notify_sha256)
  tmp=$(umask 077; mktemp "$state/.pr-observation.XXXXXX") || return 1
  if ! printf 'state=%s\nhead=%s\nchecks=%s\nconclusion=%s\nidentity=%s\nincarnation=%s\n' \
      "$pr_state" "$head" "$checks" "$conclusion" "$identity" "$incarnation" > "$tmp" \
    || ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$path"; then
    rm -f -- "$tmp"
    return 1
  fi
}

fm_human_notify_clear_task() {  # <state> <task>
  local state=$1 task=$2 f recorded
  rm -f -- "$state/$task.pr-observation"
  _fm_human_notify_receipt_dir_safe "$state" || return 1
  [ -d "$state/human-notifications" ] || return 0
  for f in "$state"/human-notifications/*; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    recorded=$(sed -n 's/^task=//p' "$f" 2>/dev/null | head -1 || true)
    [ "$recorded" = "$task" ] && rm -f -- "$f"
  done
  return 0
}

fm_human_notify_summary() {  # <state> <task> <status-line>
  local state=$1 task=$2 line=$3 class display
  class=$(fm_human_notify_class "$line") || return 1
  if [ -f "$state/$task.meta" ]; then
    display=$(fm_display_name_for_meta "$state/$task.meta" "$task")
  else
    display=$(fm_display_name_fallback "$task")
  fi
  case "$class" in
    decision)
      printf '%s: decision evidence changed. Action required: inspect the private task record and answer the question.' "$display" ;;
    blocker)
      printf '%s: blocker evidence changed. Action required: inspect the private task record and remove the blocker or provide the requested input.' "$display" ;;
    captain-hold)
      printf '%s: a captain-owned approval or decision opened. Action required: inspect the private task record and answer or defer it.' "$display" ;;
    review-ready)
      printf '%s: the review-ready result changed. Action required: inspect the private task record and approve or merge only if authorized.' "$display" ;;
    result)
      printf '%s: a new result surfaced. Action required: inspect the private task record and review the result.' "$display" ;;
    legacy-result)
      printf '%s: a new actionable update surfaced. Action required: inspect the private task record and respond.' "$display" ;;
    failure)
      printf '%s: new failure evidence surfaced. Action required: inspect the private task record and choose recovery.' "$display" ;;
  esac
}
