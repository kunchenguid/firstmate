#!/usr/bin/env bash
# fm-macos-permissions.sh - inspect firstmate's macOS TCC setup without changing it.
#
# This helper performs only read-only probes unless --open is supplied.
# It never invokes tccutil, edits a TCC database, sends Apple Events, captures
# the screen, synthesizes input, restarts a process, or tries to grant access.
# Full Disk Access and Accessibility require System Settings approval on an
# unmanaged Mac; Automation and Screen Recording can use first-use dialogs.
#
# Usage:
#   bin/fm-macos-permissions.sh
#   bin/fm-macos-permissions.sh --open full-disk-access
#   bin/fm-macos-permissions.sh --open automation
#   bin/fm-macos-permissions.sh --open screen-recording
#   bin/fm-macos-permissions.sh --open accessibility
#   bin/fm-macos-permissions.sh --help
#
# The protected-directory probe reports only the TCC-responsible context of
# this invocation. Stored TCC decisions are queried only when macOS permits
# read-only access to a TCC database; that access itself normally requires Full
# Disk Access. Automation is pairwise, so there is no honest global status.
set -u

export LC_ALL=C

usage() {
  sed -n '2,24s/^# \{0,1\}//p' "$0"
}

open_pane=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --open)
      [ "$#" -ge 2 ] || { printf 'error: --open requires a pane name\n' >&2; exit 2; }
      open_pane=$2
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      printf 'error: unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$(uname -s 2>/dev/null)" != Darwin ]; then
  printf 'error: fm-macos-permissions.sh supports macOS only.\n' >&2
  exit 1
fi

user_tcc_db="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
system_tcc_db="/Library/Application Support/com.apple.TCC/TCC.db"
readable_tcc_dbs=()
tcc_db_probe_incomplete=no

if command -v sqlite3 >/dev/null 2>&1; then
  for candidate_db in "$user_tcc_db" "$system_tcc_db"; do
    if sqlite3 -readonly "$candidate_db" 'SELECT 1 FROM access LIMIT 1;' >/dev/null 2>&1; then
      readable_tcc_dbs+=("$candidate_db")
    else
      tcc_db_probe_incomplete=yes
    fi
  done
else
  tcc_db_probe_incomplete=yes
fi

sql_quote() {
  printf '%s' "$1" | sed "s/'/''/g"
}

# stored_status <service> <client>...
# A stored allow is useful evidence, but it is not a behavioral proof that a
# newly replaced binary still matches the entry's code-signing requirement.
stored_status() {
  local service=$1 client quoted db rows values identity_status aggregate_status=""
  local saw_client=no
  shift

  [ "${#readable_tcc_dbs[@]}" -gt 0 ] && [ "$tcc_db_probe_incomplete" = no ] \
    || { printf 'UNKNOWN'; return; }
  service=$(sql_quote "$service")
  for client in "$@"; do
    [ -n "$client" ] || continue
    saw_client=yes
    quoted=$(sql_quote "$client")
    values=""
    for db in "${readable_tcc_dbs[@]}"; do
      if rows=$(sqlite3 -readonly "$db" \
        "SELECT auth_value FROM access WHERE service='$service' AND client='$quoted';" 2>/dev/null); then
        [ -z "$rows" ] || values="${values}${rows}"$'\n'
      else
        printf 'UNKNOWN'
        return
      fi
    done

    if [ -z "$values" ]; then
      identity_status='NO MATCHING STORED ROW'
    elif printf '%s' "$values" | grep -qx '2' \
      && ! printf '%s' "$values" | grep -qvx '2'; then
      identity_status='STORED ALLOW ONLY'
    elif printf '%s' "$values" | grep -qx '0' \
      && ! printf '%s' "$values" | grep -qvx '0'; then
      identity_status='STORED DENIAL ONLY'
    else
      identity_status='CONFLICTING STORED ROWS'
    fi

    if [ -z "$aggregate_status" ]; then
      aggregate_status=$identity_status
    elif [ "$aggregate_status" != "$identity_status" ]; then
      printf 'UNKNOWN (CONFLICTING STORED EVIDENCE)'
      return
    fi
  done

  [ "$saw_client" = yes ] || { printf 'UNKNOWN'; return; }
  printf 'UNKNOWN (%s)' "$aggregate_status"
}

print_automation_pairs() {
  local label=$1 condition="" client quoted db rows pairs="" query_failed=no
  shift

  printf '  %s:\n' "$label"
  if [ "${#readable_tcc_dbs[@]}" -eq 0 ] || [ "$tcc_db_probe_incomplete" = yes ]; then
    printf '%s\n' '    UNKNOWN (not all expected TCC databases are readable in this context)'
    return
  fi
  for client in "$@"; do
    [ -n "$client" ] || continue
    quoted=$(sql_quote "$client")
    if [ -n "$condition" ]; then
      condition="$condition OR "
    fi
    condition="${condition}client='$quoted'"
  done
  [ -n "$condition" ] || { printf '%s\n' '    UNKNOWN (NO AUTHORITATIVE CLIENT IDENTITY)'; return; }

  for db in "${readable_tcc_dbs[@]}"; do
    if rows=$(sqlite3 -readonly -separator '|' "$db" \
      "SELECT client, COALESCE(indirect_object_identifier, '(unknown target)'), auth_value FROM access WHERE service='kTCCServiceAppleEvents' AND ($condition);" 2>/dev/null); then
      [ -z "$rows" ] || pairs="${pairs}${rows}"$'\n'
    else
      query_failed=yes
    fi
  done
  if [ "$query_failed" = yes ]; then
    printf '%s\n' '    UNKNOWN (the TCC schema could not be queried completely)'
    return
  fi
  if [ -z "$pairs" ]; then
    printf '%s\n' '    UNKNOWN (NO MATCHING STORED ROW)'
    return
  fi

  printf '%s' "$pairs" | sort -u -t '|' -k1,1 -k2,2 -k3,3 | awk -F '|' '
    function emit() {
      if (client == "") return
      if (conflict) status = "UNKNOWN (CONFLICTING STORED ROWS)"
      else if (auth == "2") status = "UNKNOWN (STORED ALLOW ONLY)"
      else if (auth == "0") status = "UNKNOWN (STORED DENIAL ONLY)"
      else status = "UNKNOWN (UNRECOGNIZED STORED VALUE)"
      printf "    %s -> %s: %s\n", client, target, status
    }
    {
      if (client != "" && ($1 != client || $2 != target)) {
        emit()
        client = ""
      }
      if (client == "") {
        client = $1
        target = $2
        auth = $3
        conflict = 0
      } else if ($3 != auth) {
        conflict = 1
      }
    }
    END { emit() }
  '
}

full_disk_probe() {
  local protected_dir probe_error saw_directory=no accessible=no denied=no
  for protected_dir in \
    "$HOME/Library/Mail" \
    "$HOME/Library/Messages" \
    "$HOME/Library/Safari"; do
    [ -d "$protected_dir" ] || continue
    saw_directory=yes
    if probe_error=$(ls -1A "$protected_dir" 2>&1 >/dev/null); then
      accessible=yes
      continue
    fi
    case "$probe_error" in
      *'Operation not permitted'*) denied=yes ;;
      *) printf 'UNKNOWN'; return ;;
    esac
  done
  if [ "$saw_directory" = yes ] && [ "$accessible" = yes ] && [ "$denied" = no ]; then
    printf 'ACCESSIBLE'
  elif [ "$saw_directory" = yes ] && [ "$accessible" = no ] && [ "$denied" = yes ]; then
    printf 'DENIED'
  else
    printf 'UNKNOWN'
  fi
}

resolved_path() {
  local resolved=$1 link
  [ -n "$resolved" ] || return 0
  while [ -L "$resolved" ]; do
    link=$(readlink "$resolved") || break
    case "$link" in
      /*) resolved=$link ;;
      *) resolved="$(cd "$(dirname "$resolved")" && pwd -P)/$link" ;;
    esac
  done
  printf '%s\n' "$resolved"
}

resolved_command() {
  local command_name=$1 command_path
  command_path=$(command -v "$command_name" 2>/dev/null || true)
  resolved_path "$command_path"
}

has_apple_events_entitlement() {
  local executable=$1 entitlements compact key
  [ -n "$executable" ] && [ -e "$executable" ] || { printf 'UNKNOWN'; return; }
  command -v codesign >/dev/null 2>&1 || { printf 'UNKNOWN'; return; }
  if ! entitlements=$(codesign -d --entitlements :- "$executable" 2>&1); then
    printf 'UNKNOWN'
    return
  fi
  compact=$(printf '%s' "$entitlements" | tr -d '[:space:]')
  key='<key>com.apple.security.automation.apple-events</key>'
  case "$compact" in
    *"$key"'<true/>'*) printf 'PRESENT' ;;
    *"$key"'<false/>'*) printf 'MISSING' ;;
    *"$key"*) printf 'UNKNOWN' ;;
    *) printf 'MISSING' ;;
  esac
}

print_permission() {
  printf '  %-31s requirement=%-25s status=%s\n' "$1" "$2" "$3"
  printf '    %s\n' "$4"
}

ghostty_app='/Applications/Ghostty.app'
ghostty_binary="$ghostty_app/Contents/MacOS/ghostty"
claude_command=$(command -v claude 2>/dev/null || true)
claude_binary=$(resolved_command claude)
codex_command=$(command -v codex 2>/dev/null || true)
codex_binary=$(resolved_command codex)
computer_use_app="$HOME/.codex/computer-use/Codex Computer Use.app"
codex_automation_entitlement=$(has_apple_events_entitlement "$codex_binary")
case "$codex_automation_entitlement" in
  PRESENT)
    codex_automation_note='codesign reports the Apple Events entitlement as true for the current PATH command filesystem target; the active controller identity remains unknown.'
    ;;
  MISSING)
    codex_automation_note='codesign reports no true Apple Events entitlement on the current PATH command filesystem target; the active controller identity and target signing relationship remain unknown.'
    ;;
  *)
    codex_automation_note='The current Codex PATH command entitlement could not be inspected, so the active controller capability is unknown.'
    ;;
esac

current_fda=$(full_disk_probe)
ghostty_fda=$(stored_status kTCCServiceSystemPolicyAllFiles \
  com.mitchellh.ghostty "$ghostty_binary")

ghostty_screen=$(stored_status kTCCServiceScreenCapture \
  com.mitchellh.ghostty "$ghostty_binary")
ghostty_accessibility=$(stored_status kTCCServiceAccessibility \
  com.mitchellh.ghostty "$ghostty_binary")
claude_fda=$(stored_status kTCCServiceSystemPolicyAllFiles \
  com.anthropic.claude-code "$claude_command" "$claude_binary")
claude_screen=$(stored_status kTCCServiceScreenCapture \
  com.anthropic.claude-code "$claude_command" "$claude_binary")
claude_accessibility=$(stored_status kTCCServiceAccessibility \
  com.anthropic.claude-code "$claude_command" "$claude_binary")
codex_fda=$(stored_status kTCCServiceSystemPolicyAllFiles \
  codex "$codex_command" "$codex_binary" com.openai.sky.CUAService "$computer_use_app")
codex_screen=$(stored_status kTCCServiceScreenCapture \
  codex "$codex_command" "$codex_binary" com.openai.sky.CUAService "$computer_use_app")
codex_accessibility=$(stored_status kTCCServiceAccessibility \
  codex "$codex_command" "$codex_binary" com.openai.sky.CUAService "$computer_use_app")

printf '%s\n' 'firstmate macOS permission report'
printf '  unverified bundle environment hint: %s (not used for attribution)\n' \
  "${__CFBundleIdentifier:-not exposed by this process}"
printf '  current invocation protected-path probe: %s\n' "$current_fda"
if [ "$tcc_db_probe_incomplete" = no ]; then
  printf '  readable TCC databases: %s\n' "${#readable_tcc_dbs[@]}"
  printf '%s\n' '  Stored rows below are advisory; behavioral probes take precedence.'
else
  printf '  readable TCC databases: %s (at least one expected database is unreadable)\n' \
    "${#readable_tcc_dbs[@]}"
  printf '%s\n' '  Stored permission statuses therefore remain UNKNOWN unless behavior proves otherwise.'
fi
printf '%s\n' '  Automation status is always PER TARGET because macOS grants one controller-to-app relationship at a time.'
printf '\n'

printf '%s\n' 'Ghostty (terminal launcher)'
print_permission 'Full Disk Access' 'CONDITIONAL' "$ghostty_fda" \
  'Protected-path work needs the exact responsible entry macOS observes; add Ghostty only when macOS names it.'
print_permission 'Automation' 'CONDITIONAL' 'PER TARGET' \
  'The first-use Allow dialog establishes the exact controller-to-target pair for terminal-driven app automation; tmux does not use Apple Events.'
print_permission 'Screen Recording' 'CONDITIONAL' "$ghostty_screen" \
  'Native desktop capture needs the exact responsible entry macOS observes; add Ghostty only when macOS names it.'
print_permission 'Accessibility' 'CONDITIONAL' "$ghostty_accessibility" \
  'Native UI control needs the exact responsible entry macOS observes; add Ghostty only when macOS names it.'
printf '\n'

printf 'Claude Code PATH command target (%s)\n' "${claude_binary:-UNKNOWN: not found on PATH}"
print_permission 'Full Disk Access' 'LAUNCHER OR CONDITIONAL' "$claude_fda" \
  'Use the exact responsible entry macOS observes for protected-path access; command ancestry alone does not establish it.'
print_permission 'Automation' 'CONDITIONAL' 'PER TARGET' \
  'The first-use Allow dialog establishes the exact controller-to-target pair for app automation; approve Claude only when macOS names it as controller.'
print_permission 'Screen Recording' 'CONDITIONAL' "$claude_screen" \
  'Native desktop capture needs the exact responsible entry macOS observes; command ancestry does not establish it.'
print_permission 'Accessibility' 'CONDITIONAL' "$claude_accessibility" \
  'Native UI control needs the exact responsible entry macOS observes; command ancestry does not establish it.'
printf '\n'

printf 'Codex PATH command target (%s)\n' "${codex_binary:-UNKNOWN: not found on PATH}"
print_permission 'Full Disk Access' 'LAUNCHER OR CONDITIONAL' "$codex_fda" \
  'Use the exact responsible entry macOS observes for protected-path access; the current PATH command does not establish it.'
print_permission 'Automation' 'CONDITIONAL' 'UNKNOWN' "$codex_automation_note"
print_permission 'Screen Recording' 'REQUIRED FOR COMPUTER USE' "$codex_screen" \
  'Native Computer Use needs screen pixels for the exact responsible entry macOS observes; DevTools screenshots do not.'
print_permission 'Accessibility' 'REQUIRED FOR COMPUTER USE' "$codex_accessibility" \
  'Native Computer Use needs Accessibility for the exact responsible entry macOS observes.'
printf '\n'

printf '%s\n' 'Stored Automation candidate relationships (not proof of responsibility)'
print_automation_pairs 'Ghostty' com.mitchellh.ghostty "$ghostty_binary"
print_automation_pairs 'Claude Code' com.anthropic.claude-code "$claude_command" "$claude_binary"
print_automation_pairs 'Codex' codex "$codex_command" "$codex_binary" \
  com.openai.sky.CUAService "$computer_use_app"
printf '\n'

printf '%s\n' 'No grant was changed.'
printf '%s\n' 'Full Disk Access and Accessibility require a human click in System Settings.'
printf '%s\n' 'Automation and Screen Recording may first ask for approval in a dialog.'
printf '%s\n' 'Use System Settings to review or change recorded access, or to add Screen Recording access manually.'
printf '%s\n' 'Open one pane with --open full-disk-access|automation|screen-recording|accessibility.'

if [ -n "$open_pane" ]; then
  case "$open_pane" in
    full-disk-access) anchor=Privacy_AllFiles ;;
    automation) anchor=Privacy_Automation ;;
    screen-recording) anchor=Privacy_ScreenCapture ;;
    accessibility) anchor=Privacy_Accessibility ;;
    *)
      printf 'error: unknown pane: %s\n' "$open_pane" >&2
      exit 2
      ;;
  esac
  settings_uri="x-apple.systempreferences:com.apple.preference.security?$anchor"
  if open "$settings_uri"; then
    case "$open_pane" in
      automation)
        printf 'Opened %s; review or change target-specific relationships there.\n' "$settings_uri"
        ;;
      screen-recording)
        printf 'Opened %s; review, change, or manually add screen-recording access there.\n' "$settings_uri"
        ;;
      *)
        printf 'Opened %s; the human must make the grant.\n' "$settings_uri"
        ;;
    esac
  else
    printf 'error: failed to open %s\n' "$settings_uri" >&2
    exit 1
  fi
fi
