# shellcheck shell=bash
record_hygiene_report() {
  local file id output now cutoff archive dir pr seen_prs prior n file_mtime read_timeout read_status exclude
  read_timeout=${FM_RECORD_HYGIENE_READ_TIMEOUT:-10}
  case "$read_timeout" in ''|*[!0-9]*|0) read_timeout=10 ;; esac
  seen_prs=
  now=$(date +%s)
  cutoff=$((now - 86400))
  [ -d "$STATE" ] || return 0
  exclude=$(status_scan_parent_channel_exclude "$STATE")

  for file in "$STATE"/*.status; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    [ "$file" = "$exclude" ] && continue
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
          # shellcheck source=bin/fm-wake-lib.sh
          command -v fm_meta_lock_path >/dev/null 2>&1 || . "$SCRIPT_DIR/fm-wake-lib.sh"
          lock=$(fm_meta_lock_path "$STATE/$id.meta") || continue
          fm_lock_try_acquire "$lock" || continue
          if { [ ! -e "$STATE/$id.meta" ] && [ ! -L "$STATE/$id.meta" ]; } \
            && [ -f "$file" ] && [ ! -L "$file" ]; then
            file_mtime=$(_fm_status_file_mtime "$file" 2>/dev/null) || file_mtime=
            case "$file_mtime" in ''|*[!0-9]*) file_mtime= ;; esac
            if [ -n "$file_mtime" ] && [ "$file_mtime" -lt "$cutoff" ]; then
              # shellcheck disable=SC2153 # DATA is set by the sourcing script (fm-bootstrap.sh).
              mkdir -p -- "$DATA" || { fm_lock_release "$lock"; continue; }
              dir=$(CDPATH='' cd -- "$DATA" && pwd -P) || { fm_lock_release "$lock"; continue; }
              dir="$dir/$id"
              if { [ ! -e "$dir" ] && [ ! -L "$dir" ]; } || { [ -d "$dir" ] && [ ! -L "$dir" ]; }; then
                mkdir -p -- "$dir" || { fm_lock_release "$lock"; continue; }
                archive="$dir/status.log"
                n=0
                while [ -e "$archive" ] || [ -L "$archive" ]; do
                  n=$((n + 1))
                  archive="$dir/status.$n.log"
                done
                if mv -- "$file" "$archive"; then
                  # Start status-archive retention at archive time, not at the
                  # orphan's last write, so teardown's 30-day prune keeps it.
                  touch -- "$archive" || echo "RECORD_HYGIENE: could not refresh archived status log time: $id" >&2
                else
                  echo "RECORD_HYGIENE: could not archive orphan status log: $id" >&2
                fi
              fi
            fi
          fi
          fm_lock_release "$lock"
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
    if [ -z "$(fm_meta_get "$file" window)" ]; then
      echo "RECORD_HYGIENE: metadata has no tab: $id"
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
      [ -n "$id" ] || continue
      case "$id" in
        */*) echo "RECORD_HYGIENE: In-flight backlog row without metadata: $id" ;;
        *) [ -f "$STATE/$id.meta" ] && [ ! -L "$STATE/$id.meta" ] || echo "RECORD_HYGIENE: In-flight backlog row without metadata: $id" ;;
      esac
    done < <(printf '%s\n' "$output" | awk '
      /^tasks\[[0-9][0-9]*\]\{/ { rows=1; next }
      rows && /^[[:space:]]/ {
        sub(/^[[:space:]]+/, "")
        if (substr($0, 1, 1) == "\"") {
          value = substr($0, 2)
          gsub(/""/, "\034", value)
          sub(/".*/, "", value)
          gsub(/\034/, "\"", value)
        } else {
          sub(/,.*/, "")
          value = $0
        }
        if (value != "") print value
        next
      }
      { rows=0 }
    ')
  fi
}
