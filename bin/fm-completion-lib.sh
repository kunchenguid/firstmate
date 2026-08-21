#!/usr/bin/env bash
# Shared schema and identity helpers for observation-only crew completion data.
#
# The two fixed-path receipts are independent signals:
#
#   state/<id>.completion-receipt
#   state/<id>.process-exit-receipt
#
# A completion receipt records worker intent and observable artifact identity.
# A process-exit receipt records only the exact harness child's lifetime result.
# Neither receipt is landing proof, merge authority, cleanup eligibility, or
# permission to call fm-teardown.sh. Git cleanliness, forge state, and teardown's
# landed-work proof remain separate contracts owned by their existing scripts.
#
# Both schemas are strict line-oriented key/value records. Writers publish with
# a private temporary file plus rename while holding the task metadata lock.
# Readers must validate the schema and compare spawn_gen with current metadata;
# a syntactically valid receipt from another incarnation is stale, not current.

FM_COMPLETION_SCHEMA=fm-completion-receipt.v1
FM_PROCESS_EXIT_SCHEMA=fm-process-exit-receipt.v1

fm_completion_token_valid() {
  local value=${1-}
  case "$value" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

fm_completion_field() {  # <file> <key>
  local file=$1 key=$2
  grep "^$key=" "$file" 2>/dev/null | cut -d= -f2-
}

fm_completion_schema_shape_valid() {  # <file> <type>
  local file=$1 type=$2
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  case "$type" in
    completion)
      awk -F= '
        BEGIN {
          split("schema task_id spawn_gen kind mode outcome artifact_path worktree_head created_epoch pr_url", allowed, " ")
          for (i in allowed) known[allowed[i]] = 1
        }
        !($1 in known) { bad = 1 }
        { count[$1]++ }
        END {
          required = "schema task_id spawn_gen kind mode outcome artifact_path worktree_head created_epoch"
          n = split(required, keys, " ")
          for (i = 1; i <= n; i++) if (count[keys[i]] != 1) bad = 1
          if (count["pr_url"] > 1) bad = 1
          exit bad
        }
      ' "$file"
      ;;
    process-exit)
      awk -F= '
        BEGIN {
          required = "schema task_id spawn_gen harness backend process_pid process_identity exit_epoch wait_status"
          n = split(required, keys, " ")
          for (i = 1; i <= n; i++) known[keys[i]] = 1
        }
        !($1 in known) { bad = 1 }
        { count[$1]++ }
        END {
          for (i = 1; i <= n; i++) if (count[keys[i]] != 1) bad = 1
          exit bad
        }
      ' "$file"
      ;;
    *) return 1 ;;
  esac
}

fm_completion_receipt_load() {  # <file> [expected-task] [expected-spawn-gen]
  local file=$1 expected_task=${2-} expected_spawn=${3-}
  fm_completion_schema_shape_valid "$file" completion || return 1
  FM_COMPLETION_TASK_ID=$(fm_completion_field "$file" task_id) || return 1
  FM_COMPLETION_SPAWN_GEN=$(fm_completion_field "$file" spawn_gen) || return 1
  FM_COMPLETION_KIND=$(fm_completion_field "$file" kind) || return 1
  FM_COMPLETION_MODE=$(fm_completion_field "$file" mode) || return 1
  FM_COMPLETION_OUTCOME=$(fm_completion_field "$file" outcome) || return 1
  FM_COMPLETION_ARTIFACT_PATH=$(fm_completion_field "$file" artifact_path) || return 1
  FM_COMPLETION_WORKTREE_HEAD=$(fm_completion_field "$file" worktree_head) || return 1
  FM_COMPLETION_CREATED_EPOCH=$(fm_completion_field "$file" created_epoch) || return 1
  FM_COMPLETION_PR_URL=$(fm_completion_field "$file" pr_url 2>/dev/null || true)
  [ "$(fm_completion_field "$file" schema)" = "$FM_COMPLETION_SCHEMA" ] || return 1
  fm_completion_token_valid "$FM_COMPLETION_TASK_ID" || return 1
  fm_completion_token_valid "$FM_COMPLETION_SPAWN_GEN" || return 1
  case "$FM_COMPLETION_KIND:$FM_COMPLETION_MODE" in
    scout:scout|ship:no-mistakes|ship:direct-PR|ship:local-only) : ;;
    *) return 1 ;;
  esac
  case "$FM_COMPLETION_OUTCOME" in done|failed) : ;; *) return 1 ;; esac
  case "$FM_COMPLETION_CREATED_EPOCH" in ''|*[!0-9]*) return 1 ;; esac
  fm_pr_head_valid "$FM_COMPLETION_WORKTREE_HEAD" || return 1
  if [ "$FM_COMPLETION_KIND" = scout ]; then
    [ -n "$FM_COMPLETION_ARTIFACT_PATH" ] || return 1
  fi
  case "$FM_COMPLETION_ARTIFACT_PATH" in *$'\n'*|*$'\r'*) return 1 ;; esac
  if [ -n "$FM_COMPLETION_PR_URL" ]; then
    fm_pr_url_parse "$FM_COMPLETION_PR_URL" || return 1
    [ "$FM_PR_URL" = "$FM_COMPLETION_PR_URL" ] || return 1
  fi
  [ -z "$expected_task" ] || [ "$FM_COMPLETION_TASK_ID" = "$expected_task" ] || return 1
  [ -z "$expected_spawn" ] || [ "$FM_COMPLETION_SPAWN_GEN" = "$expected_spawn" ] || return 1
}

fm_process_exit_receipt_load() {  # <file> [expected-task] [expected-spawn-gen]
  local file=$1 expected_task=${2-} expected_spawn=${3-}
  fm_completion_schema_shape_valid "$file" process-exit || return 1
  FM_PROCESS_EXIT_TASK_ID=$(fm_completion_field "$file" task_id) || return 1
  FM_PROCESS_EXIT_SPAWN_GEN=$(fm_completion_field "$file" spawn_gen) || return 1
  FM_PROCESS_EXIT_HARNESS=$(fm_completion_field "$file" harness) || return 1
  FM_PROCESS_EXIT_BACKEND=$(fm_completion_field "$file" backend) || return 1
  FM_PROCESS_EXIT_PID=$(fm_completion_field "$file" process_pid) || return 1
  FM_PROCESS_EXIT_IDENTITY=$(fm_completion_field "$file" process_identity) || return 1
  FM_PROCESS_EXIT_EPOCH=$(fm_completion_field "$file" exit_epoch) || return 1
  FM_PROCESS_EXIT_WAIT_STATUS=$(fm_completion_field "$file" wait_status) || return 1
  [ "$(fm_completion_field "$file" schema)" = "$FM_PROCESS_EXIT_SCHEMA" ] || return 1
  fm_completion_token_valid "$FM_PROCESS_EXIT_TASK_ID" || return 1
  fm_completion_token_valid "$FM_PROCESS_EXIT_SPAWN_GEN" || return 1
  case "$FM_PROCESS_EXIT_HARNESS" in claude|codex|opencode|pi|pi-signed|grok|kimi|cursor|muse) : ;; *) return 1 ;; esac
  case "$FM_PROCESS_EXIT_BACKEND" in tmux|herdr|zellij|orca|cmux) : ;; *) return 1 ;; esac
  case "$FM_PROCESS_EXIT_PID" in ''|*[!0-9]*) return 1 ;; esac
  case "$FM_PROCESS_EXIT_IDENTITY" in ''|*[!0-9a-f]*) return 1 ;; esac
  [ $(( ${#FM_PROCESS_EXIT_IDENTITY} % 2 )) -eq 0 ] || return 1
  case "$FM_PROCESS_EXIT_EPOCH" in ''|*[!0-9]*) return 1 ;; esac
  case "$FM_PROCESS_EXIT_WAIT_STATUS" in ''|*[!0-9]*) return 1 ;; esac
  [ "$FM_PROCESS_EXIT_WAIT_STATUS" -le 255 ] || return 1
  [ -z "$expected_task" ] || [ "$FM_PROCESS_EXIT_TASK_ID" = "$expected_task" ] || return 1
  [ -z "$expected_spawn" ] || [ "$FM_PROCESS_EXIT_SPAWN_GEN" = "$expected_spawn" ] || return 1
}

fm_completion_process_identity() {  # <pid>
  local pid=$1 proc_root stat_line starttime value raw
  local -a stat_fields
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  if [ -r "$proc_root/$pid/stat" ]; then
    stat_line=$(cat "$proc_root/$pid/stat" 2>/dev/null) || return 1
    read -r -a stat_fields <<< "${stat_line##*)}"
    [ "${#stat_fields[@]}" -ge 20 ] || return 1
    starttime=${stat_fields[19]}
    case "$starttime" in ''|*[!0-9]*) return 1 ;; esac
    raw="starttime=$starttime"
  else
    value=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null) || return 1
    value=$(printf '%s' "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -n "$value" ] || return 1
    raw="lstart=$value"
  fi
  printf '%s' "$raw" | od -An -v -tx1 | tr -d '[:space:]'
}
