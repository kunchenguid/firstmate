record_hygiene_report() {
  local file id output now cutoff archive dir pr seen_prs prior backend target endpoint_state n file_mtime read_timeout read_status
  read_timeout=${FM_RECORD_HYGIENE_READ_TIMEOUT:-10}
  case "$read_timeout" in ''|*[!0-9]*|0) read_timeout=10 ;; esac
  seen_prs=
  now=$(date +%s)
  cutoff=$((now - 86400))
  [ -d "$STATE" ] || return 0

  for file in "$STATE"/*.status; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    id=${file##*/}
    id=${id%.status}
    if [ ! -e "$STATE/$id.meta" ]; then
      file_mtime=$(_fm_status_file_mtime "$file" 2>/dev/null) || file_mtime=
      case "$file_mtime" in ''|*[!0-9]*) continue ;; esac
      if [ "$file_mtime" -lt "$cutoff" ]; then
        echo "RECORD_HYGIENE: status log without metadata older than 24 hours: $id"
        # Archive only in the locked, mutating bootstrap pass. Detect-only startup
        # must remain read-only.
        if [ "${FM_BOOTSTRAP_DETECT_ONLY:-0}" != 1 ]; then
          case "$id" in ''|.*|*[!A-Za-z0-9._-]*) continue ;; esac
          mkdir -p -- "$DATA" || continue
          dir=$(CDPATH='' cd -- "$DATA" && pwd -P) || continue
          dir="$dir/$id"
          if { [ ! -e "$dir" ] && [ ! -L "$dir" ]; } || { [ -d "$dir" ] && [ ! -L "$dir" ]; }; then
            mkdir -p -- "$dir" || continue
            archive="$dir/status.log"
            n=0
            while [ -e "$archive" ] || [ -L "$archive" ]; do
              n=$((n + 1))
              archive="$dir/status.$n.log"
            done
            mv -- "$file" "$archive" || echo "RECORD_HYGIENE: could not archive orphan status log: $id" >&2
          fi
        fi
      fi
    fi
  done

  for file in "$STATE"/*.meta; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    id=${file##*/}
    id=${id%.meta}
    [ "$(fm_meta_get "$file" kind)" = secondmate ] && continue
    [ -n "$(fm_meta_get "$file" remote_host)" ] && continue
    backend=$(fm_backend_of_meta "$file")
    target=$(fm_backend_target_of_meta "$file")
    if [ -z "$backend" ] || [ -z "$target" ]; then
      echo "RECORD_HYGIENE: metadata has no endpoint: $id"
    else
      # shellcheck disable=SC2016 # The timed child receives the function and arguments as positional parameters.
      if fm_run_timed "$read_timeout" bash -c 'source "$1"; shift; "$@"' _ "$SCRIPT_DIR/fm-backend.sh" fm_backend_target_exists "$backend" "$target" >/dev/null 2>&1; then
        :
      else
        read_status=$?
        if fm_timed_out "$read_status"; then
          echo "RECORD_HYGIENE: endpoint read timed out after ${read_timeout}s: $id"
        else
          # shellcheck disable=SC2016 # The timed child receives the function and arguments as positional parameters.
          endpoint_state=$(fm_run_timed "$read_timeout" bash -c 'source "$1"; shift; "$@"' _ "$SCRIPT_DIR/fm-backend.sh" fm_backend_agent_state "$backend" "$target" 2>/dev/null)
          read_status=$?
          if fm_timed_out "$read_status"; then
            echo "RECORD_HYGIENE: endpoint read timed out after ${read_timeout}s: $id"
          elif [ "$endpoint_state" = missing ]; then
            echo "RECORD_HYGIENE: metadata has no endpoint: $id"
          elif [ "$endpoint_state" = unreadable ]; then
            echo "RECORD_HYGIENE: metadata endpoint could not be read: $id"
          elif [ "$endpoint_state" = unverified ]; then
            echo "RECORD_HYGIENE: metadata endpoint could not be verified: $id"
          fi
        fi
      fi
    fi
    pr=$(sed -n 's/^pr=//p' "$file" | head -1)
    [ -n "$pr" ] || continue
    prior=$(printf '%s' "$seen_prs" | awk -F '\t' -v pr="$pr" '$1 == pr { print $2; exit }')
    if [ -n "$prior" ]; then
      echo "RECORD_HYGIENE: duplicate PR $pr in records: $prior, $id"
    else
      seen_prs="$(printf '%s\t%s' "$pr" "$id")"$'\n'"$seen_prs"
    fi
  done

  if command -v tasks-axi >/dev/null 2>&1 && [ -d "$DATA" ]; then
    output=$(FM_TASKS_AXI_TIMEOUT="$read_timeout" fm_backlog_row_list "$DATA" --state in_flight 2>&1)
    read_status=$?
    if fm_timed_out "$read_status"; then
      echo "RECORD_HYGIENE: In-flight backlog read timed out after ${read_timeout}s"
      return 0
    elif [ "$read_status" -ne 0 ]; then
      echo "RECORD_HYGIENE: In-flight backlog read failed (exit=$read_status): $(printf '%s' "$output" | head -1)"
      return 0
    fi
    while IFS= read -r id; do
      [ -n "$id" ] && [ ! -e "$STATE/$id.meta" ] && echo "RECORD_HYGIENE: In-flight backlog row without metadata: $id"
    done < <(printf '%s\n' "$output" | awk '
      /^tasks\[[0-9][0-9]*\]\{/ { rows=1; next }
      rows && /^[[:space:]]/ {
        sub(/^[[:space:]]+/, "")
        split($0, fields, ",")
        if (fields[1] != "") print fields[1]
        next
      }
      { rows=0 }
    ')
  fi
}
