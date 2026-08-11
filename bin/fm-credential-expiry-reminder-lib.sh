#!/usr/bin/env bash
# Credential-expiry reminder metadata for fm-bootstrap.sh.
#
# Configuration: config/credential-expiry-reminders.json (LOCAL, gitignored;
# docs/configuration.md owns its schema).  This library reads only that
# metadata.  It never reads a credential file, runs an auth check, selects a
# provider, or changes any credential.
#
# State: state/credential-expiry-reminders/<cksum>.state.  Each regular state
# file contains the configured UTC expiry and its last-surfaced epoch.  State
# is written only by a mutable bootstrap run after the diagnostic is printed;
# detect-only bootstrap is deliberately read-only.  A matching reminder is
# re-surfaced at most once every seven days, and an expiry change bypasses that
# throttle immediately.
#
# Shell interface:
#   fm_credential_expiry_reminders_report <config-dir> <state-dir> <mutable>
# Prints zero or more typed bootstrap diagnostics and returns zero.  Malformed
# configuration and unsafe reminder state print a diagnostic without changing
# the corresponding file.

FM_CREDENTIAL_EXPIRY_REMINDER_FILE=credential-expiry-reminders.json
FM_CREDENTIAL_EXPIRY_REMINDER_WARNING_SECONDS=$((14 * 24 * 60 * 60))
FM_CREDENTIAL_EXPIRY_REMINDER_CADENCE_SECONDS=$((7 * 24 * 60 * 60))

fm_credential_expiry_reminder_now() {
  case "${FM_CREDENTIAL_EXPIRY_REMINDER_NOW:-}" in
    '') date -u +%s ;;
    *[!0-9]*) return 1 ;;
    *) printf '%s\n' "$FM_CREDENTIAL_EXPIRY_REMINDER_NOW" ;;
  esac
}

fm_credential_expiry_reminder_parse() { # <path>
  node - "$1" <<'NODE'
const fs = require("fs");
const file = process.argv[2];
const fail = (message) => {
  process.stderr.write(`${message}\n`);
  process.exit(1);
};
let value;
try {
  value = JSON.parse(fs.readFileSync(file, "utf8"));
} catch (_) {
  fail("must be valid JSON");
}
if (value === null || Array.isArray(value) || typeof value !== "object") fail("must be an object");
if (Object.keys(value).length !== 2 || value.version !== 1 || !Object.hasOwn(value, "reminders")) {
  fail("must contain only version: 1 and reminders");
}
if (!Array.isArray(value.reminders) || value.reminders.length > 32) fail("reminders must be an array of at most 32 entries");
const labels = new Set();
for (const reminder of value.reminders) {
  if (reminder === null || Array.isArray(reminder) || typeof reminder !== "object"
      || Object.keys(reminder).length !== 2 || !Object.hasOwn(reminder, "label") || !Object.hasOwn(reminder, "expiresAt")) {
    fail("each reminder must contain only label and expiresAt");
  }
  if (typeof reminder.label !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._/-]{0,63}$/.test(reminder.label)) {
    fail("each label must use 1-64 ASCII letters, digits, dot, underscore, slash, or hyphen");
  }
  if (labels.has(reminder.label)) fail("labels must be unique");
  labels.add(reminder.label);
  if (typeof reminder.expiresAt !== "string" || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(reminder.expiresAt)) {
    fail("each expiresAt must be a UTC timestamp such as 2026-09-09T00:00:00Z");
  }
  const milliseconds = Date.parse(reminder.expiresAt);
  if (!Number.isFinite(milliseconds) || new Date(milliseconds).toISOString() !== reminder.expiresAt.replace("Z", ".000Z")) {
    fail("each expiresAt must be a real UTC timestamp");
  }
  process.stdout.write(`${reminder.label}\t${reminder.expiresAt}\t${Math.floor(milliseconds / 1000)}\n`);
}
NODE
}

fm_credential_expiry_reminder_key() { # <label>
  printf '%s' "$1" | cksum | awk '{print $1 "-" $2}'
}

fm_credential_expiry_reminder_link_count() { # <path>
  if [ "$(uname)" = Darwin ]; then
    stat -f %l "$1" 2>/dev/null
  else
    stat -c %h "$1" 2>/dev/null
  fi
}

fm_credential_expiry_reminder_interval() { # <seconds>
  local seconds=$1 days hours minutes
  days=$((seconds / 86400))
  hours=$(((seconds % 86400) / 3600))
  minutes=$(((seconds % 3600) / 60))
  if [ "$days" -gt 0 ]; then
    printf '%sd %sh' "$days" "$hours"
  else
    printf '%sh %sm' "$hours" "$minutes"
  fi
}

fm_credential_expiry_reminder_state_read() { # <path>
  local path=$1 first second third expires last links
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  links=$(fm_credential_expiry_reminder_link_count "$path") || return 1
  [ "$links" = 1 ] || return 1
  [ "$(wc -l < "$path" | tr -d '[:space:]')" = 2 ] || return 1
  first=$(sed -n '1p' "$path")
  second=$(sed -n '2p' "$path")
  third=$(sed -n '3p' "$path")
  [ -z "$third" ] || return 1
  case "$first" in expires_at=*) expires=${first#expires_at=} ;; *) return 1 ;; esac
  case "$second" in last_surfaced_epoch=*) last=${second#last_surfaced_epoch=} ;; *) return 1 ;; esac
  case "$last" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\t%s\n' "$expires" "$last"
}

fm_credential_expiry_reminder_state_write() { # <dir> <key> <expires-at> <now>
  local dir=$1 key=$2 expires=$3 now=$4 tmp
  tmp=$(umask 077; mktemp "$dir/.${key}.XXXXXX") || return 1
  if ! printf 'expires_at=%s\nlast_surfaced_epoch=%s\n' "$expires" "$now" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! mv -f "$tmp" "$dir/$key.state"; then
    rm -f "$tmp"
    return 1
  fi
}

fm_credential_expiry_reminders_report() { # <config-dir> <state-dir> <mutable 0|1>
  local config_dir=$1 state_dir=$2 mutable=$3 config now parsed parser_error label expires epoch key state state_expires state_last remaining links
  config="$config_dir/$FM_CREDENTIAL_EXPIRY_REMINDER_FILE"
  [ -e "$config" ] || return 0
  if [ ! -f "$config" ] || [ -L "$config" ]; then
    printf 'CREDENTIAL_EXPIRY_REMINDER: invalid config/%s - must be a regular file\n' "$FM_CREDENTIAL_EXPIRY_REMINDER_FILE"
    return 0
  fi
  links=$(fm_credential_expiry_reminder_link_count "$config") || {
    printf 'CREDENTIAL_EXPIRY_REMINDER: invalid config/%s - could not inspect file links\n' "$FM_CREDENTIAL_EXPIRY_REMINDER_FILE"
    return 0
  }
  if [ "$links" != 1 ]; then
    printf 'CREDENTIAL_EXPIRY_REMINDER: invalid config/%s - must not be hardlinked\n' "$FM_CREDENTIAL_EXPIRY_REMINDER_FILE"
    return 0
  fi
  command -v node >/dev/null 2>&1 || return 0
  if ! now=$(fm_credential_expiry_reminder_now); then
    printf 'CREDENTIAL_EXPIRY_REMINDER: invalid test clock FM_CREDENTIAL_EXPIRY_REMINDER_NOW\n'
    return 0
  fi
  parser_error=$(mktemp "${TMPDIR:-/tmp}/fm-credential-expiry-reminder.XXXXXX") || {
    printf 'CREDENTIAL_EXPIRY_REMINDER: unable to validate config/%s\n' "$FM_CREDENTIAL_EXPIRY_REMINDER_FILE"
    return 0
  }
  if ! parsed=$(fm_credential_expiry_reminder_parse "$config" 2>"$parser_error"); then
    printf 'CREDENTIAL_EXPIRY_REMINDER: invalid config/%s - %s\n' "$FM_CREDENTIAL_EXPIRY_REMINDER_FILE" "$(head -n 1 "$parser_error")"
    rm -f "$parser_error"
    return 0
  fi
  rm -f "$parser_error"

  while IFS=$'\t' read -r label expires epoch; do
    [ -n "$label" ] || continue
    remaining=$((epoch - now))
    [ "$remaining" -le "$FM_CREDENTIAL_EXPIRY_REMINDER_WARNING_SECONDS" ] || continue
    key=$(fm_credential_expiry_reminder_key "$label")
    state="$state_dir/credential-expiry-reminders/$key.state"
    state_expires=
    state_last=
    if [ -e "$state" ] || [ -L "$state" ]; then
      if ! state=$(fm_credential_expiry_reminder_state_read "$state"); then
        printf 'CREDENTIAL_EXPIRY_REMINDER: invalid reminder state for %s - delete state/credential-expiry-reminders/%s.state and retry\n' "$label" "$key"
        continue
      fi
      IFS=$'\t' read -r state_expires state_last <<EOF
$state
EOF
    fi
    if [ "$state_expires" = "$expires" ] && [ -n "$state_last" ] \
      && [ $((now - state_last)) -lt "$FM_CREDENTIAL_EXPIRY_REMINDER_CADENCE_SECONDS" ]; then
      continue
    fi
    if [ "$remaining" -le 0 ]; then
      printf 'CREDENTIAL_EXPIRY_REMINDER_EXPIRED: %s expired %s (%s ago); update config/%s; metadata only - not credential validation\n' \
        "$label" "$expires" "$(fm_credential_expiry_reminder_interval "$((-remaining))")" "$FM_CREDENTIAL_EXPIRY_REMINDER_FILE"
    else
      printf 'CREDENTIAL_EXPIRY_REMINDER: %s expires %s (in %s); update config/%s\n' \
        "$label" "$expires" "$(fm_credential_expiry_reminder_interval "$remaining")" "$FM_CREDENTIAL_EXPIRY_REMINDER_FILE"
    fi
    if [ "$mutable" = 1 ]; then
      if [ ! -d "$state_dir/credential-expiry-reminders" ]; then
        mkdir -p "$state_dir/credential-expiry-reminders" 2>/dev/null || {
          printf 'CREDENTIAL_EXPIRY_REMINDER: cannot record reminder state\n'
          continue
        }
      fi
      if [ -L "$state_dir/credential-expiry-reminders" ] || ! fm_credential_expiry_reminder_state_write \
        "$state_dir/credential-expiry-reminders" "$key" "$expires" "$now"; then
        printf 'CREDENTIAL_EXPIRY_REMINDER: cannot record reminder state\n'
      fi
    fi
  done <<EOF
$parsed
EOF
}
