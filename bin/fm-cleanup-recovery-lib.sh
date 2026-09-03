#!/usr/bin/env bash
# Closed, Firstmate-owned recovery records for launched endpoints whose delivery
# did not reach its commit point.  The private sidecar is authoritative when a
# task-meta rewrite fails; mutable status prose is never an input.

FM_CLEANUP_RECOVERY_SCHEMA=fm-cleanup-recovery.v1
FM_CLEANUP_RECOVERY_KIND=
FM_CLEANUP_RECOVERY_FAILURE=
FM_CLEANUP_RECOVERY_CLEANUP=
FM_CLEANUP_RECOVERY_PROFILE=
FM_CLEANUP_RECOVERY_BACKEND=
FM_CLEANUP_RECOVERY_CONTROL_RELAUNCH_TX=
FM_CLEANUP_RECOVERY_SIDECAR=
FM_CLEANUP_RECOVERY_ERROR=
FM_CLEANUP_RECOVERY_TASK_KIND=
FM_CLEANUP_RECOVERY_WINDOW=
FM_CLEANUP_RECOVERY_SESSION=
FM_CLEANUP_RECOVERY_WORKSPACE=
FM_CLEANUP_RECOVERY_TAB=
FM_CLEANUP_RECOVERY_PANE=
FM_CLEANUP_RECOVERY_ENDPOINT_TASK_ID=

fm_cleanup_recovery_path() { # <state> <id>
  printf '%s/%s.cleanup-recovery\n' "$1" "$2"
}

fm_cleanup_recovery_token_valid() {
  case "${1-}" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac
}

fm_cleanup_recovery_herdr_scoped_id_valid() {
  local value=${1-} scope item
  case "$value" in
    *:*) scope=${value%%:*}; item=${value#*:} ;;
    *) return 1 ;;
  esac
  case "$item" in *:*) return 1 ;; esac
  fm_cleanup_recovery_token_valid "$scope" && fm_cleanup_recovery_token_valid "$item"
}

fm_cleanup_recovery_herdr_scoped_to_workspace() { # <scoped-id> <workspace>
  fm_cleanup_recovery_herdr_scoped_id_valid "$1" && [ "${1%%:*}" = "$2" ]
}

fm_cleanup_recovery_failure_valid() {
  case "${1-}" in
    gotmp|trace-setup|launch-text|launch-enter|readiness|prompt-encoding|prompt-delivery|backlog-transition|signal-hup|signal-int|signal-term|post-publication) return 0 ;;
  esac
  return 1
}

fm_cleanup_recovery_private_file() { # <path>
  local path=$1 uid mode links
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  uid=$(stat -c %u "$path" 2>/dev/null || stat -f %u "$path" 2>/dev/null) || return 1
  mode=$(stat -c %a "$path" 2>/dev/null || stat -f %Lp "$path" 2>/dev/null) || return 1
  links=$(stat -c %h "$path" 2>/dev/null || stat -f %l "$path" 2>/dev/null) || return 1
  [ "$uid" = "$(id -u)" ] && [ "$mode" = 600 ] && [ "$links" = 1 ]
}

fm_cleanup_recovery_value_exact() { # <file> <key>
  local file=$1 key=$2 count
  count=$(grep -c "^${key}=" "$file" 2>/dev/null || true)
  [ "$count" -eq 1 ] || return 1
  sed -n "s/^${key}=//p" "$file"
}

fm_cleanup_recovery_sidecar_validate() { # <state> <id> [expected-spawn-gen]
  local state=$1 id=$2 expected_gen=${3:-} sidecar schema task spawn_gen kind failure cleanup
  local harness profile backend task_kind window session workspace tab pane endpoint tx extra expected
  FM_CLEANUP_RECOVERY_ERROR=
  fm_backlog_directory_present "$state" "state directory" || {
    FM_CLEANUP_RECOVERY_ERROR=$FM_BACKLOG_TRANSITION_ERROR
    return 1
  }
  fm_cleanup_recovery_token_valid "$id" || { FM_CLEANUP_RECOVERY_ERROR="invalid recovery task id"; return 1; }
  sidecar=$(fm_cleanup_recovery_path "$state" "$id")
  fm_backlog_record_present "$sidecar" "cleanup-recovery record" "$state" || {
    FM_CLEANUP_RECOVERY_ERROR=$FM_BACKLOG_TRANSITION_ERROR
    return 1
  }
  fm_cleanup_recovery_private_file "$sidecar" || {
    FM_CLEANUP_RECOVERY_ERROR="cleanup-recovery record is not a private, singly-linked owner file: $sidecar"
    return 1
  }
  schema=$(fm_cleanup_recovery_value_exact "$sidecar" schema) || return 1
  task=$(fm_cleanup_recovery_value_exact "$sidecar" task_id) || return 1
  spawn_gen=$(fm_cleanup_recovery_value_exact "$sidecar" spawn_gen) || return 1
  kind=$(fm_cleanup_recovery_value_exact "$sidecar" cleanup_recovery) || return 1
  failure=$(fm_cleanup_recovery_value_exact "$sidecar" delivery_failure) || return 1
  cleanup=$(fm_cleanup_recovery_value_exact "$sidecar" delivery_cleanup) || return 1
  harness=$(fm_cleanup_recovery_value_exact "$sidecar" harness) || return 1
  profile=$(fm_cleanup_recovery_value_exact "$sidecar" profile) || return 1
  backend=$(fm_cleanup_recovery_value_exact "$sidecar" backend) || return 1
  task_kind=$(fm_cleanup_recovery_value_exact "$sidecar" kind) || return 1
  window=$(fm_cleanup_recovery_value_exact "$sidecar" window) || return 1
  session=$(fm_cleanup_recovery_value_exact "$sidecar" herdr_session) || return 1
  workspace=$(fm_cleanup_recovery_value_exact "$sidecar" herdr_workspace_id) || return 1
  tab=$(fm_cleanup_recovery_value_exact "$sidecar" herdr_tab_id) || return 1
  pane=$(fm_cleanup_recovery_value_exact "$sidecar" herdr_pane_id) || return 1
  endpoint=$(fm_cleanup_recovery_value_exact "$sidecar" endpoint_task_id) || return 1
  tx=$(fm_cleanup_recovery_value_exact "$sidecar" control_relaunch_tx) || return 1
  extra=$(awk -F= '!($1 ~ /^(schema|task_id|spawn_gen|cleanup_recovery|delivery_failure|delivery_cleanup|harness|profile|backend|kind|window|herdr_session|herdr_workspace_id|herdr_tab_id|herdr_pane_id|endpoint_task_id|control_relaunch_tx)$/){print; exit}' "$sidecar")
  [ -z "$extra" ] || { FM_CLEANUP_RECOVERY_ERROR="unknown cleanup-recovery field"; return 1; }
  [ "$schema" = "$FM_CLEANUP_RECOVERY_SCHEMA" ] && [ "$task" = "$id" ] \
    && [ "$kind" = omp-delivery ] && [ "$harness" = omp ] && [ "$backend" = herdr ] \
    && [ "$endpoint" = "$id" ] || { FM_CLEANUP_RECOVERY_ERROR="cleanup-recovery identity mismatch"; return 1; }
  fm_cleanup_recovery_token_valid "$spawn_gen" || { FM_CLEANUP_RECOVERY_ERROR="invalid recovery generation"; return 1; }
  [ -z "$expected_gen" ] || [ "$spawn_gen" = "$expected_gen" ] \
    || { FM_CLEANUP_RECOVERY_ERROR="cleanup-recovery generation mismatch"; return 1; }
  fm_cleanup_recovery_failure_valid "$failure" || { FM_CLEANUP_RECOVERY_ERROR="invalid OMP delivery failure"; return 1; }
  case "$cleanup" in confirmed|unconfirmed) ;; *) FM_CLEANUP_RECOVERY_ERROR="invalid OMP cleanup evidence"; return 1 ;; esac
  case "$profile" in personal|sf) ;; *) FM_CLEANUP_RECOVERY_ERROR="invalid OMP profile"; return 1 ;; esac
  case "$task_kind" in ship|scout) ;; *) FM_CLEANUP_RECOVERY_ERROR="invalid OMP task kind"; return 1 ;; esac
  fm_cleanup_recovery_token_valid "$session" && fm_cleanup_recovery_token_valid "$workspace" \
    && fm_cleanup_recovery_herdr_scoped_to_workspace "$tab" "$workspace" \
    && fm_cleanup_recovery_herdr_scoped_to_workspace "$pane" "$workspace" \
    || { FM_CLEANUP_RECOVERY_ERROR="invalid Herdr recovery binding"; return 1; }
  expected="$session:$pane"
  [ "$window" = "$expected" ] || { FM_CLEANUP_RECOVERY_ERROR="recovery endpoint mismatch"; return 1; }
  [ -z "$tx" ] || fm_cleanup_recovery_token_valid "$tx" \
    || { FM_CLEANUP_RECOVERY_ERROR="invalid relaunch transaction"; return 1; }
  FM_CLEANUP_RECOVERY_KIND=$kind
  FM_CLEANUP_RECOVERY_FAILURE=$failure
  FM_CLEANUP_RECOVERY_CLEANUP=$cleanup
  FM_CLEANUP_RECOVERY_PROFILE=$profile
  FM_CLEANUP_RECOVERY_BACKEND=$backend
  FM_CLEANUP_RECOVERY_CONTROL_RELAUNCH_TX=$tx
  FM_CLEANUP_RECOVERY_SIDECAR=$sidecar
  FM_CLEANUP_RECOVERY_TASK_KIND=$task_kind
  FM_CLEANUP_RECOVERY_WINDOW=$window
  FM_CLEANUP_RECOVERY_SESSION=$session
  FM_CLEANUP_RECOVERY_WORKSPACE=$workspace
  FM_CLEANUP_RECOVERY_TAB=$tab
  FM_CLEANUP_RECOVERY_PANE=$pane
  FM_CLEANUP_RECOVERY_ENDPOINT_TASK_ID=$endpoint
}

fm_cleanup_recovery_publish_omp() { # <state> <id> <gen> <failure> <cleanup> <profile> <kind> <window> <session> <workspace> <tab> <pane> [tx]
  local state=$1 id=$2 gen=$3 failure=$4 cleanup=$5 profile=$6 task_kind=$7 window=$8
  local session=$9 workspace=${10} tab=${11} pane=${12} tx=${13:-} sidecar tmp
  sidecar=$(fm_cleanup_recovery_path "$state" "$id")
  fm_backlog_directory_present "$state" "state directory" || return 1
  fm_cleanup_recovery_failure_valid "$failure" || return 1
  fm_cleanup_recovery_token_valid "$id" && fm_cleanup_recovery_token_valid "$gen" \
    && fm_cleanup_recovery_token_valid "$session" && fm_cleanup_recovery_token_valid "$workspace" \
    && fm_cleanup_recovery_herdr_scoped_to_workspace "$tab" "$workspace" \
    && fm_cleanup_recovery_herdr_scoped_to_workspace "$pane" "$workspace" \
    || return 1
  [ "$window" = "$session:$pane" ] || return 1
  [ -z "$tx" ] || fm_cleanup_recovery_token_valid "$tx" || return 1
  case "$cleanup:$profile:$task_kind" in
    confirmed:personal:ship|confirmed:personal:scout|confirmed:sf:ship|confirmed:sf:scout|unconfirmed:personal:ship|unconfirmed:personal:scout|unconfirmed:sf:ship|unconfirmed:sf:scout) ;;
    *) return 1 ;;
  esac
  tmp=$(umask 077; mktemp "$state/.$id.cleanup-recovery.XXXXXX") || return 1
  {
    printf 'schema=%s\n' "$FM_CLEANUP_RECOVERY_SCHEMA"
    printf 'task_id=%s\n' "$id"
    printf 'spawn_gen=%s\n' "$gen"
    printf 'cleanup_recovery=omp-delivery\n'
    printf 'delivery_failure=%s\n' "$failure"
    printf 'delivery_cleanup=%s\n' "$cleanup"
    printf 'harness=omp\n'
    printf 'profile=%s\n' "$profile"
    printf 'backend=herdr\n'
    printf 'kind=%s\n' "$task_kind"
    printf 'window=%s\n' "$window"
    printf 'herdr_session=%s\n' "$session"
    printf 'herdr_workspace_id=%s\n' "$workspace"
    printf 'herdr_tab_id=%s\n' "$tab"
    printf 'herdr_pane_id=%s\n' "$pane"
    printf 'endpoint_task_id=%s\n' "$id"
    printf 'control_relaunch_tx=%s\n' "$tx"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  fm_backlog_atomic_transition publish "$tmp" "$sidecar" "cleanup-recovery record" "$state" \
    || { rm -f -- "$tmp"; return 1; }
  fm_cleanup_recovery_sidecar_validate "$state" "$id" "$gen"
}

fm_cleanup_recovery_meta_validate() { # <meta> <state> <id>
  local meta=$1 state=$2 id=$3 kind profile backend failure cleanup endpoint window session workspace tab pane tx task_kind
  fm_backlog_record_present "$meta" "task record" "$state" || return 1
  kind=$(fm_meta_get "$meta" cleanup_recovery)
  case "$kind" in
    '') return 3 ;;
    orca) FM_CLEANUP_RECOVERY_KIND=orca; return 0 ;;
    omp-delivery) ;;
    *) FM_CLEANUP_RECOVERY_ERROR="unknown cleanup recovery kind: $kind"; return 1 ;;
  esac
  for key in cleanup_recovery delivery_failure delivery_cleanup harness profile backend kind window herdr_session herdr_workspace_id herdr_tab_id herdr_pane_id endpoint_task_id spawn_gen; do
    [ "$(grep -c "^${key}=" "$meta" 2>/dev/null || true)" -eq 1 ] || return 1
  done
  [ "$(grep -c '^control_relaunch_tx=' "$meta" 2>/dev/null || true)" -le 1 ] || return 1
  [ "$(fm_meta_get "$meta" harness)" = omp ] || return 1
  profile=$(fm_meta_get "$meta" profile)
  backend=$(fm_meta_get "$meta" backend)
  failure=$(fm_meta_get "$meta" delivery_failure)
  cleanup=$(fm_meta_get "$meta" delivery_cleanup)
  endpoint=$(fm_meta_get "$meta" endpoint_task_id)
  window=$(fm_meta_get "$meta" window)
  session=$(fm_meta_get "$meta" herdr_session)
  workspace=$(fm_meta_get "$meta" herdr_workspace_id)
  tab=$(fm_meta_get "$meta" herdr_tab_id)
  pane=$(fm_meta_get "$meta" herdr_pane_id)
  tx=$(fm_meta_get "$meta" control_relaunch_tx)
  task_kind=$(fm_meta_get "$meta" kind)
  case "$profile:$backend:$cleanup" in personal:herdr:confirmed|personal:herdr:unconfirmed|sf:herdr:confirmed|sf:herdr:unconfirmed) ;; *) return 1 ;; esac
  case "$task_kind" in ship|scout) ;; *) return 1 ;; esac
  fm_cleanup_recovery_failure_valid "$failure" || return 1
  fm_cleanup_recovery_token_valid "$id" && fm_cleanup_recovery_token_valid "$session" \
    && fm_cleanup_recovery_token_valid "$workspace" \
    && fm_cleanup_recovery_herdr_scoped_to_workspace "$tab" "$workspace" \
    && fm_cleanup_recovery_herdr_scoped_to_workspace "$pane" "$workspace" || return 1
  [ -z "$tx" ] || fm_cleanup_recovery_token_valid "$tx" || return 1
  [ "$endpoint" = "$id" ] && [ "$window" = "$session:$pane" ] || return 1
  FM_CLEANUP_RECOVERY_KIND=omp-delivery
  FM_CLEANUP_RECOVERY_FAILURE=$failure
  FM_CLEANUP_RECOVERY_CLEANUP=$cleanup
  FM_CLEANUP_RECOVERY_PROFILE=$profile
  FM_CLEANUP_RECOVERY_BACKEND=$backend
  FM_CLEANUP_RECOVERY_CONTROL_RELAUNCH_TX=$tx
  FM_CLEANUP_RECOVERY_TASK_KIND=$task_kind
  FM_CLEANUP_RECOVERY_WINDOW=$window
  FM_CLEANUP_RECOVERY_SESSION=$session
  FM_CLEANUP_RECOVERY_WORKSPACE=$workspace
  FM_CLEANUP_RECOVERY_TAB=$tab
  FM_CLEANUP_RECOVERY_PANE=$pane
  FM_CLEANUP_RECOVERY_ENDPOINT_TASK_ID=$endpoint
}

fm_cleanup_recovery_decode() { # <state> <meta> <id>
  local state=$1 meta=$2 id=$3 sidecar meta_rc sidecar_present=0 meta_gen
  local mk mf mc mp mb mt mtk mw ms mws mtab mpane me
  local sk sf sc sp sb st stk sw ss sws stab spane se
  FM_CLEANUP_RECOVERY_KIND=
  FM_CLEANUP_RECOVERY_FAILURE=
  FM_CLEANUP_RECOVERY_CLEANUP=
  FM_CLEANUP_RECOVERY_PROFILE=
  FM_CLEANUP_RECOVERY_BACKEND=
  FM_CLEANUP_RECOVERY_CONTROL_RELAUNCH_TX=
  FM_CLEANUP_RECOVERY_SIDECAR=
  FM_CLEANUP_RECOVERY_ERROR=
  FM_CLEANUP_RECOVERY_TASK_KIND=
  FM_CLEANUP_RECOVERY_WINDOW=
  FM_CLEANUP_RECOVERY_SESSION=
  FM_CLEANUP_RECOVERY_WORKSPACE=
  FM_CLEANUP_RECOVERY_TAB=
  FM_CLEANUP_RECOVERY_PANE=
  FM_CLEANUP_RECOVERY_ENDPOINT_TASK_ID=
  sidecar=$(fm_cleanup_recovery_path "$state" "$id")
  [ ! -e "$sidecar" ] && [ ! -L "$sidecar" ] || sidecar_present=1
  meta_rc=0
  fm_cleanup_recovery_meta_validate "$meta" "$state" "$id" || meta_rc=$?
  if [ "$meta_rc" -ne 0 ] && [ "$meta_rc" -ne 3 ]; then
    FM_CLEANUP_RECOVERY_ERROR="malformed cleanup recovery in $meta"
    return 1
  fi
  if [ "$meta_rc" -eq 0 ]; then
    mk=$FM_CLEANUP_RECOVERY_KIND; mf=$FM_CLEANUP_RECOVERY_FAILURE; mc=$FM_CLEANUP_RECOVERY_CLEANUP
    mp=$FM_CLEANUP_RECOVERY_PROFILE; mb=$FM_CLEANUP_RECOVERY_BACKEND; mt=$FM_CLEANUP_RECOVERY_CONTROL_RELAUNCH_TX
    mtk=$FM_CLEANUP_RECOVERY_TASK_KIND; mw=$FM_CLEANUP_RECOVERY_WINDOW; ms=$FM_CLEANUP_RECOVERY_SESSION
    mws=$FM_CLEANUP_RECOVERY_WORKSPACE; mtab=$FM_CLEANUP_RECOVERY_TAB; mpane=$FM_CLEANUP_RECOVERY_PANE
    me=$FM_CLEANUP_RECOVERY_ENDPOINT_TASK_ID
  fi
  if [ "$sidecar_present" = 1 ]; then
    [ "$(grep -c '^spawn_gen=' "$meta" 2>/dev/null || true)" -eq 1 ] || {
      FM_CLEANUP_RECOVERY_ERROR="cleanup-recovery task record has no unique generation"
      return 1
    }
    meta_gen=$(fm_meta_get "$meta" spawn_gen)
    fm_cleanup_recovery_token_valid "$meta_gen" || {
      FM_CLEANUP_RECOVERY_ERROR="cleanup-recovery task record has an invalid generation"
      return 1
    }
    fm_cleanup_recovery_sidecar_validate "$state" "$id" "$meta_gen" || return 1
    sk=$FM_CLEANUP_RECOVERY_KIND; sf=$FM_CLEANUP_RECOVERY_FAILURE; sc=$FM_CLEANUP_RECOVERY_CLEANUP
    sp=$FM_CLEANUP_RECOVERY_PROFILE; sb=$FM_CLEANUP_RECOVERY_BACKEND; st=$FM_CLEANUP_RECOVERY_CONTROL_RELAUNCH_TX
    stk=$FM_CLEANUP_RECOVERY_TASK_KIND; sw=$FM_CLEANUP_RECOVERY_WINDOW; ss=$FM_CLEANUP_RECOVERY_SESSION
    sws=$FM_CLEANUP_RECOVERY_WORKSPACE; stab=$FM_CLEANUP_RECOVERY_TAB; spane=$FM_CLEANUP_RECOVERY_PANE
    se=$FM_CLEANUP_RECOVERY_ENDPOINT_TASK_ID
    if [ "$meta_rc" -eq 0 ] \
       && [ "$mk|$mf|$mc|$mp|$mb|$mt|$mtk|$mw|$ms|$mws|$mtab|$mpane|$me" \
            != "$sk|$sf|$sc|$sp|$sb|$st|$stk|$sw|$ss|$sws|$stab|$spane|$se" ]; then
      FM_CLEANUP_RECOVERY_ERROR="conflicting task and sidecar cleanup recovery"
      return 1
    fi
    return 0
  fi
  [ "$meta_rc" -eq 0 ] && return 0
  FM_CLEANUP_RECOVERY_KIND=
  return 0
}

fm_cleanup_recovery_remove_sidecar() { # <state> <id> [expected-gen]
  local state=$1 id=$2 gen=${3:-} sidecar
  sidecar=$(fm_cleanup_recovery_path "$state" "$id")
  [ -e "$sidecar" ] || [ -L "$sidecar" ] || return 0
  fm_cleanup_recovery_sidecar_validate "$state" "$id" "$gen" || return 1
  fm_backlog_atomic_transition remove "$sidecar" "cleanup-recovery record" "$state"
}

# Make the task record independently authoritative before retiring its recovery
# sidecar.  A sidecar-only record is an intentional fallback when spawn-time
# annotation fails, but removing that sidecar first would make a crash leave an
# ordinary-looking task record that teardown could no longer recognize.
fm_cleanup_recovery_ensure_meta_annotation() { # <state> <meta> <id>
  local state=$1 meta=$2 id=$3 meta_rc=0 tmp expected actual
  local failure cleanup sidecar
  sidecar=$(fm_cleanup_recovery_path "$state" "$id")

  fm_cleanup_recovery_decode "$state" "$meta" "$id" || return 1
  [ "$FM_CLEANUP_RECOVERY_KIND" = omp-delivery ] || {
    FM_CLEANUP_RECOVERY_ERROR="task is not an OMP delivery recovery"
    return 1
  }
  expected="$FM_CLEANUP_RECOVERY_KIND|$FM_CLEANUP_RECOVERY_FAILURE|$FM_CLEANUP_RECOVERY_CLEANUP|$FM_CLEANUP_RECOVERY_PROFILE|$FM_CLEANUP_RECOVERY_BACKEND|$FM_CLEANUP_RECOVERY_CONTROL_RELAUNCH_TX|$FM_CLEANUP_RECOVERY_TASK_KIND|$FM_CLEANUP_RECOVERY_WINDOW|$FM_CLEANUP_RECOVERY_SESSION|$FM_CLEANUP_RECOVERY_WORKSPACE|$FM_CLEANUP_RECOVERY_TAB|$FM_CLEANUP_RECOVERY_PANE|$FM_CLEANUP_RECOVERY_ENDPOINT_TASK_ID"
  failure=$FM_CLEANUP_RECOVERY_FAILURE
  cleanup=$FM_CLEANUP_RECOVERY_CLEANUP

  fm_cleanup_recovery_meta_validate "$meta" "$state" "$id" || meta_rc=$?
  [ "$meta_rc" -eq 0 ] && return 0
  [ "$meta_rc" -eq 3 ] || {
    FM_CLEANUP_RECOVERY_ERROR="malformed cleanup recovery in $meta"
    return 1
  }
  fm_cleanup_recovery_sidecar_validate "$state" "$id" "$(fm_meta_get "$meta" spawn_gen)" || return 1

  tmp=$(umask 077; mktemp "$state/.$id.meta.cleanup-recovery.XXXXXX") || {
    FM_CLEANUP_RECOVERY_ERROR="could not stage task recovery annotation"
    return 1
  }
  if ! awk -F= '$1 != "cleanup_recovery" && $1 != "delivery_failure" && $1 != "delivery_cleanup"' "$meta" > "$tmp" \
     || ! {
       printf 'cleanup_recovery=omp-delivery\n'
       printf 'delivery_failure=%s\n' "$failure"
       printf 'delivery_cleanup=%s\n' "$cleanup"
     } >> "$tmp" \
     || ! chmod 600 "$tmp"; then
    rm -f -- "$tmp"
    FM_CLEANUP_RECOVERY_ERROR="could not stage task recovery annotation"
    return 1
  fi

  meta_rc=0
  fm_cleanup_recovery_meta_validate "$tmp" "$state" "$id" || meta_rc=$?
  actual="$FM_CLEANUP_RECOVERY_KIND|$FM_CLEANUP_RECOVERY_FAILURE|$FM_CLEANUP_RECOVERY_CLEANUP|$FM_CLEANUP_RECOVERY_PROFILE|$FM_CLEANUP_RECOVERY_BACKEND|$FM_CLEANUP_RECOVERY_CONTROL_RELAUNCH_TX|$FM_CLEANUP_RECOVERY_TASK_KIND|$FM_CLEANUP_RECOVERY_WINDOW|$FM_CLEANUP_RECOVERY_SESSION|$FM_CLEANUP_RECOVERY_WORKSPACE|$FM_CLEANUP_RECOVERY_TAB|$FM_CLEANUP_RECOVERY_PANE|$FM_CLEANUP_RECOVERY_ENDPOINT_TASK_ID"
  if [ "$meta_rc" -ne 0 ] || [ "$actual" != "$expected" ]; then
    rm -f -- "$tmp"
    FM_CLEANUP_RECOVERY_ERROR="task record does not match its authoritative cleanup-recovery sidecar"
    return 1
  fi
  if ! fm_backlog_atomic_transition publish "$tmp" "$meta" "task recovery annotation" "$state"; then
    rm -f -- "$tmp" 2>/dev/null || true
    FM_CLEANUP_RECOVERY_ERROR=${FM_BACKLOG_TRANSITION_ERROR:-"task recovery annotation could not be published"}
    return 1
  fi
  fm_cleanup_recovery_decode "$state" "$meta" "$id"
}

# Retire OMP recovery records in recovery-first order.  If metadata removal
# fails after the sidecar is gone, the already-validated annotation is still a
# complete retry record. The closed transaction mode prevents a failed
# relaunch from being mistaken for a fresh delivery merely because this home
# has no automatic backlog.
fm_cleanup_recovery_retire_task_records() { # <fresh|relaunch> <state> <meta> <id>
  local mode=$1 state=$2 meta=$3 id=$4 gen
  fm_cleanup_recovery_ensure_meta_annotation "$state" "$meta" "$id" || return 1
  case "$mode:$FM_CLEANUP_RECOVERY_CONTROL_RELAUNCH_TX" in
    fresh:) ;;
    relaunch:?*) ;;
    fresh:?*)
      FM_CLEANUP_RECOVERY_ERROR="fresh recovery retirement requires non-relaunch OMP delivery evidence"
      return 1
      ;;
    relaunch:)
      FM_CLEANUP_RECOVERY_ERROR="relaunch recovery retirement requires a transaction-bound OMP delivery"
      return 1
      ;;
    *)
      FM_CLEANUP_RECOVERY_ERROR="invalid OMP recovery retirement mode"
      return 2
      ;;
  esac
  [ "$(grep -c '^spawn_gen=' "$meta" 2>/dev/null || true)" -eq 1 ] || {
    FM_CLEANUP_RECOVERY_ERROR="OMP recovery task record has no unique generation"
    return 1
  }
  gen=$(fm_meta_get "$meta" spawn_gen)
  fm_cleanup_recovery_token_valid "$gen" || {
    FM_CLEANUP_RECOVERY_ERROR="OMP recovery task record has an invalid generation"
    return 1
  }
  fm_cleanup_recovery_remove_sidecar "$state" "$id" "$gen" || return 1
  fm_backlog_atomic_transition remove "$meta" "task record" "$state"
}

fm_cleanup_recovery_retire_fresh_task() { # <state> <meta> <id>
  fm_cleanup_recovery_retire_task_records fresh "$@"
}

fm_cleanup_recovery_retire_relaunch_task() { # <state> <meta> <id>
  fm_cleanup_recovery_retire_task_records relaunch "$@"
}
