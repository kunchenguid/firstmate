#!/usr/bin/env bash
# Drain state/telegram-inbox/ and execute the closed Stage-2 command grammar.
#
# Usage:
#   fm-telegram-respond.sh              # process every inbox file
#   fm-telegram-respond.sh <update_id>  # process one file if present
#
# Closed grammar (anything else is refused with an audit entry and a short
# reply): status | approve <key> | deny <key> [reason] | merge <full PR URL>
#
# Security (see docs/telegram-mode.md and the design threat model):
#   - only processes inbox files already allowlisted by fm-telegram-poll.sh
#   - freshness window for approve/deny/merge (status always allowed)
#   - rate limit + command dedupe
#   - merge only for a PR URL previously sent to this chat AND green
#   - never exits away mode; never executes free-text / Stage 3 prompts
#   - destructive/security-sensitive ops are refused
#
# For approve/deny/merge, writes state/telegram-actions/<update_id>.json for
# firstmate to apply through normal lifecycle (the skill owns captain-facing
# application). Prints one machine line per processed update:
#   ok <update_id> <verb> ...
#   refused <update_id> <reason>
#   deferred <update_id> rate-limited
#   quarantined <update_id> <reason>   # permanent: invalid-envelope | unsafe-inbox
#   error <update_id> <reason>
# Permanently-unprocessable inbox files are moved to state/telegram-inbox-quarantine/
# (audited, never reprocessed, never silently deleted). Transient failures
# (missing-jq, rate-limit DEFER, action-write, inbox-dir perms) keep the file
# queued for retry.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-telegram-lib.sh
. "$SCRIPT_DIR/fm-telegram-lib.sh"

fmt_load_config
if ! fmt_mode_enabled; then
  exit 0
fi

ONLY_ID=${1-}
case "$ONLY_ID" in
  -h|--help)
    cat <<'EOF'
Usage: fm-telegram-respond.sh [<update_id>]

Drain Telegram inbox files and run the closed Stage-2 command grammar.
EOF
    exit 0
    ;;
esac

INBOX="$STATE/telegram-inbox"
[ -d "$INBOX" ] || exit 0

# Optional hook for tests: a command that receives the PR URL and exits 0 when
# green/mergeable. Production default uses gh-axi when available.
pr_is_green() {
  local url=$1
  local parts owner repo number out rollup state draft merged summary rollup_total tail
  local check_path check_data check_total page page_total page_records page_completed page_allowed fetched
  local status_path status_data status_total status_state raw_total
  if [ -n "${FM_TELEGRAM_PR_CHECK_HOOK:-}" ]; then
    # shellcheck disable=SC2086
    $FM_TELEGRAM_PR_CHECK_HOOK "$url"
    return $?
  fi
  if command -v gh-axi >/dev/null 2>&1; then
    parts=$(fmt_github_pr_parts "$url") || return 1
    owner=$(printf '%s' "$parts" | awk -F'\t' '{print $1}')
    repo=$(printf '%s' "$parts" | awk -F'\t' '{print $2}')
    number=$(printf '%s' "$parts" | awk -F'\t' '{print $3}')
    out=$(gh-axi pr view "$number" -R "$owner/$repo" 2>/dev/null) || return 1
    state=$(printf '%s\n' "$out" | sed -n 's/^  state: //p' | head -n1)
    draft=$(printf '%s\n' "$out" | sed -n 's/^  draft: //p' | head -n1)
    merged=$(printf '%s\n' "$out" | sed -n 's/^  merged: //p' | head -n1)
    [ "$state" = open ] && [ "$draft" = no ] && [ "$merged" = no ] || return 1
    rollup=$(gh-axi pr checks "$number" -R "$owner/$repo" 2>/dev/null) || return 1
    summary=$(printf '%s\n' "$rollup" | sed -n 's/^summary: "\(.*\)"$/\1/p' | head -n1)
    [ -n "$summary" ] || return 1
    tail=${summary##*, }
    rollup_total=${tail%% total}
    case "$rollup_total" in
      ''|*[!0-9]*) return 1 ;;
    esac
    check_total=
    fetched=0
    page=1
    while :; do
      check_path="/repos/$owner/$repo/commits/refs%2Fpull%2F${number}%2Fhead/check-runs?filter=latest&per_page=100&page=$page"
      check_data=$(gh-axi api "$check_path" 2>/dev/null) || return 1
      page_total=$(printf '%s\n' "$check_data" | sed -n 's/^total_count: //p' | head -n1)
      case "$page_total" in
        ''|*[!0-9]*) return 1 ;;
      esac
      [ "$page_total" -ge 0 ] 2>/dev/null || return 1
      if [ -z "$check_total" ]; then
        check_total=$page_total
      else
        [ "$page_total" -eq "$check_total" ] || return 1
      fi
      page_records=$(printf '%s\n' "$check_data" \
        | awk '$0 ~ /^    status: / { count++ } END { print count + 0 }')
      page_completed=$(printf '%s\n' "$check_data" \
        | awk '$0 == "    status: completed" { count++ } END { print count + 0 }')
      page_allowed=$(printf '%s\n' "$check_data" \
        | awk '$0 ~ /^    conclusion: (success|neutral|skipped)$/ { count++ } END { print count + 0 }')
      [ "$page_completed" -eq "$page_records" ] \
        && [ "$page_allowed" -eq "$page_records" ] || return 1
      fetched=$((fetched + page_records))
      [ "$fetched" -le "$check_total" ] || return 1
      [ "$fetched" -eq "$check_total" ] && break
      [ "$page_records" -gt 0 ] || return 1
      page=$((page + 1))
    done
    status_path="/repos/$owner/$repo/commits/refs%2Fpull%2F${number}%2Fhead/status?per_page=100"
    status_data=$(gh-axi api "$status_path" 2>/dev/null) || return 1
    status_total=$(printf '%s\n' "$status_data" | sed -n 's/^total_count: //p' | head -n1)
    status_state=$(printf '%s\n' "$status_data" | sed -n 's/^state: //p' | head -n1)
    case "$status_total" in
      ''|*[!0-9]*) return 1 ;;
    esac
    if [ "$status_total" -gt 0 ] && [ "$status_state" != success ]; then
      return 1
    fi
    raw_total=$((check_total + status_total))
    [ "$raw_total" -gt 0 ] && [ "$rollup_total" -eq "$raw_total" ] || return 1
    return 0
  fi
  # Without gh-axi, refuse merge rather than guessing.
  return 1
}

reply_text() {
  local text=$1
  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-telegram-reply.XXXXXX") || return 1
  printf '%s\n' "$text" > "$tmp"
  # --reply bypasses AFK-only so command acks always reach the phone.
  "$SCRIPT_DIR/fm-telegram-send.sh" --text-file "$tmp" --reply >/dev/null 2>&1
  rc=$?
  rm -f "$tmp"
  return "$rc"
}

# Durable action record failed: tell the captain, keep the inbox file so a
# later sweep retries, and report a machine-readable error line.
action_write_failed() {
  local uid=$1 verb=$2
  fmt_audit_append respond error "update_id=$uid verb=$verb action-write-failed"
  reply_text "Error: could not record the $verb command; it was NOT applied. It stays queued for retry - or handle it from the desk." || true
  printf 'error %s action-write-failed\n' "$uid"
}

# Permanently-unprocessable inbox inputs: quarantine so poll never re-wakes.
# Transient failures (missing-jq, rate-limit, action-write) keep the file queued.
# On successful quarantine, send a GENERIC phone ack only (captain decision
# key=no-reply-on-quarantine): never echo command content, envelope text, or
# any secret/token material.
inbox_quarantine_permanent() {
  local uid=$1 reason=$2
  if fmt_inbox_quarantine "$uid" "$reason" >/dev/null 2>&1; then
    fmt_audit_append respond quarantined "update_id=$uid reason=$reason"
    # Fixed string only - no reason detail, no inbox text, no tokens.
    reply_text "A command could not be processed and was set aside for desk review." || true
    printf 'quarantined %s %s\n' "$uid" "$reason"
    return 0
  fi
  # Quarantine itself failed: audit and leave the file so a later pass retries
  # the quarantine move rather than silently dropping evidence.
  fmt_audit_append respond error "update_id=$uid quarantine-failed reason=$reason"
  printf 'error %s quarantine-failed\n' "$uid"
  return 0
}

# Transient read failures keep the inbox file for a later sweep.
inbox_read_failed_transient() {
  local uid=$1 reason=$2
  fmt_audit_append respond error "update_id=$uid inbox-read-failed reason=$reason"
  printf 'error %s inbox-read-failed\n' "$uid"
}

process_one() {
  local file=$1
  local base uid envelope text msg_date parsed verb key reason url fp lookup task note

  base=$(basename "$file")
  case "$base" in
    *.json) uid=${base%.json} ;;
    *) return 0 ;;
  esac
  case "$uid" in
    ''|.*|*/*|*[!A-Za-z0-9._-]*) return 0 ;;
  esac

  if ! fmx_private_artifact_dir_device "$INBOX" >/dev/null 2>&1; then
    # Transient: one chmod on the directory heals every queued file, so this
    # must not permanently quarantine well-formed commands.
    inbox_read_failed_transient "$uid" "unsafe-inbox-dir"
    return 0
  fi
  if ! fmx_private_artifact_file_valid "$INBOX" "$base" 600; then
    # Permanent: file mode/ownership cannot self-heal on retry.
    inbox_quarantine_permanent "$uid" "unsafe-inbox"
    return 0
  fi

  if ! command -v jq >/dev/null 2>&1; then
    # Transient: tool/environment gap; poll backs off while jq is absent.
    inbox_read_failed_transient "$uid" missing-jq
    return 0
  fi
  if ! envelope=$(jq -ce '
    if ((.text | type) == "string")
      and (.date == null or ((.date | type) == "number" and .date == (.date | floor)))
    then {text: .text, date: .date}
    else error("invalid inbox envelope")
    end
  ' "$file" 2>/dev/null); then
    # Permanent: malformed envelope cannot succeed on retry.
    inbox_quarantine_permanent "$uid" "invalid-envelope"
    return 0
  fi
  if ! text=$(printf '%s' "$envelope" | jq -r '.text' 2>/dev/null) \
    || ! msg_date=$(printf '%s' "$envelope" | jq -r '.date // empty' 2>/dev/null); then
    inbox_quarantine_permanent "$uid" "invalid-envelope"
    return 0
  fi
  if [ -z "$text" ]; then
    fmt_audit_append respond refused "update_id=$uid empty"
    rm -f -- "$file" 2>/dev/null || true
    printf 'refused %s empty\n' "$uid"
    return 0
  fi

  if ! fmt_rate_allow inbound; then
    # DEFER, never drop (captain decision key=telegram-rate-cap): the offset
    # already advanced past this update, so the inbox file is the only copy.
    fmt_audit_append respond deferred "update_id=$uid rate-limited"
    if ! fmt_dedupe_seen "rate-deferred:$uid"; then
      fmt_dedupe_mark "rate-deferred:$uid"
      reply_text "Rate limited - command queued; it runs on a later sweep." || true
    fi
    printf 'deferred %s rate-limited\n' "$uid"
    return 0
  fi

  parsed=$(fmt_parse_command "$text") || {
    verb=$(printf '%s' "$parsed" | awk -F'\t' '{print $2}')
    [ -n "$verb" ] || verb=unknown-command
    fmt_audit_append respond refused-scope "update_id=$uid reason=$verb text=$(printf '%s' "$text" | head -c 80)"
    reply_text "Refused: only status, approve <key>, deny <key> [reason], or merge <full green PR URL>." || true
    rm -f -- "$file" 2>/dev/null || true
    printf 'refused %s scope %s\n' "$uid" "$verb"
    return 0
  }

  verb=$(printf '%s' "$parsed" | awk -F'\t' '{print $1}')
  key=$(printf '%s' "$parsed" | awk -F'\t' '{print $2}')
  reason=$(printf '%s' "$parsed" | awk -F'\t' '{print $3}')

  # Dedupe identical commands.
  fp="${verb}:${key}:${reason}"
  if fmt_dedupe_seen "$fp"; then
    fmt_audit_append respond deduped "update_id=$uid fp=$fp"
    reply_text "Duplicate command ignored." || true
    rm -f -- "$file" 2>/dev/null || true
    printf 'refused %s deduped\n' "$uid"
    return 0
  fi

  case "$verb" in
    status)
      summary=$(fmt_status_summary)
      if reply_text "$summary"; then
        fmt_dedupe_mark "$fp"
        fmt_audit_append respond ok "update_id=$uid verb=status"
        rm -f -- "$file" 2>/dev/null || true
        printf 'ok %s status\n' "$uid"
      else
        fmt_audit_append respond error "update_id=$uid status-send-failed"
        printf 'error %s status-send-failed\n' "$uid"
      fi
      return 0
      ;;
    approve|deny)
      if ! fmt_fresh_enough "$msg_date"; then
        fmt_audit_append respond dropped-stale "update_id=$uid verb=$verb key=$key"
        reply_text "Stale command (older than freshness window). Re-send from the desk or phone if still needed." || true
        rm -f -- "$file" 2>/dev/null || true
        printf 'refused %s stale\n' "$uid"
        return 0
      fi
      if ! lookup=$(fmt_open_decision_lookup "$key"); then
        fmt_audit_append respond refused "update_id=$uid verb=$verb unknown-key=$key"
        reply_text "No open decision keyed '$key'." || true
        rm -f -- "$file" 2>/dev/null || true
        printf 'refused %s unknown-key\n' "$uid"
        return 0
      fi
      task=$(printf '%s' "$lookup" | awk -F'\t' '{print $1}')
      note=$(printf '%s' "$lookup" | awk -F'\t' '{print $3}')
      # Desk-only carve-out: refuse security-sensitive decision notes.
      case "$(printf '%s' "$note" | tr '[:upper:]' '[:lower:]')" in
        *credential*|*secret*|*token*|*password*|*destructive*|*irreversible*|*security-sensitive*|*discard*|*force*|*teardown*)
          fmt_audit_append respond refused "update_id=$uid verb=$verb desk-only key=$key"
          reply_text "Flagged for the desk: this decision is outside Telegram authority." || true
          rm -f -- "$file" 2>/dev/null || true
          printf 'refused %s desk-only\n' "$uid"
          return 0
          ;;
      esac
      if [ "$verb" = approve ]; then
        fmt_action_write "$uid" approve "$key" "$task" >/dev/null \
          || { action_write_failed "$uid" approve; return 0; }
        reply_text "Approval recorded for '$key'. Firstmate will apply it." || true
      else
        fmt_action_write "$uid" deny "$key" "$task" "$reason" >/dev/null \
          || { action_write_failed "$uid" deny; return 0; }
        if [ -n "$reason" ]; then
          reply_text "Denial recorded for '$key': $reason" || true
        else
          reply_text "Denial recorded for '$key'." || true
        fi
      fi
      fmt_dedupe_mark "$fp"
      fmt_audit_append respond ok "update_id=$uid verb=$verb key=$key task=$task"
      rm -f -- "$file" 2>/dev/null || true
      printf 'ok %s %s %s %s\n' "$uid" "$verb" "$key" "$task"
      return 0
      ;;
    merge)
      url=$key
      if ! fmt_fresh_enough "$msg_date"; then
        fmt_audit_append respond dropped-stale "update_id=$uid verb=merge"
        reply_text "Stale merge command. Re-send if still needed." || true
        rm -f -- "$file" 2>/dev/null || true
        printf 'refused %s stale\n' "$uid"
        return 0
      fi
      if ! fmt_notified_pr_seen "$url"; then
        fmt_audit_append respond refused "update_id=$uid verb=merge unknown-pr"
        reply_text "Refused: that PR was not previously sent to this Telegram chat with its full URL." || true
        rm -f -- "$file" 2>/dev/null || true
        printf 'refused %s unknown-pr\n' "$uid"
        return 0
      fi
      if ! pr_is_green "$url"; then
        fmt_audit_append respond refused "update_id=$uid verb=merge not-green"
        reply_text "Refused: PR is not green (or status could not be verified). Desk merge only." || true
        rm -f -- "$file" 2>/dev/null || true
        printf 'refused %s not-green\n' "$uid"
        return 0
      fi
      fmt_action_write "$uid" merge "$url" >/dev/null \
        || { action_write_failed "$uid" merge; return 0; }
      reply_text "Merge authorized for $url (green, previously notified). Firstmate will merge." || true
      fmt_dedupe_mark "$fp"
      fmt_audit_append respond ok "update_id=$uid verb=merge url=$url"
      rm -f -- "$file" 2>/dev/null || true
      printf 'ok %s merge %s\n' "$uid" "$url"
      return 0
      ;;
    *)
      fmt_audit_append respond refused-scope "update_id=$uid verb=$verb"
      reply_text "Refused: unknown command." || true
      rm -f -- "$file" 2>/dev/null || true
      printf 'refused %s scope\n' "$uid"
      return 0
      ;;
  esac
}

if [ -n "$ONLY_ID" ]; then
  case "$ONLY_ID" in
    *[!A-Za-z0-9._-]*) echo "error: bad update_id" >&2; exit 1 ;;
  esac
  f="$INBOX/$ONLY_ID.json"
  [ -f "$f" ] || exit 0
  process_one "$f"
  exit 0
fi

for f in "$INBOX"/*.json; do
  [ -f "$f" ] || continue
  process_one "$f"
done
exit 0
