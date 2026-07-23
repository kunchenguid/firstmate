#!/usr/bin/env bash
# Evidence-backed capacity classification and cooldown-cache helpers.
#
# This substrate is deliberately passive.
# Nothing here changes dispatch or spawn behavior by itself; callers must opt in
# by invoking the helpers or future feature-gated code.

fm_capacity_now_epoch() {
  if [ -n "${FM_CAPACITY_NOW_EPOCH:-}" ]; then
    printf '%s\n' "$FM_CAPACITY_NOW_EPOCH"
  else
    date +%s
  fi
}

fm_capacity_iso_now() {
  node -e 'console.log(new Date().toISOString())'
}

fm_capacity_reset_fields() {  # <text>
  FM_CAPACITY_TEXT=$1 FM_CAPACITY_NOW=$(fm_capacity_now_epoch) node <<'NODE'
const text = process.env.FM_CAPACITY_TEXT || "";
const nowEpoch = Number(process.env.FM_CAPACITY_NOW || Math.floor(Date.now() / 1000));
const now = new Date(nowEpoch * 1000);
const candidates = [
  /\bretry-after\s*[:=]\s*([0-9]+)\b/i,
  /\bretry after\s+([0-9]+)\s*(?:seconds?|secs?)\b/i,
  /\b(20\d\d-\d\d-\d\dT\d\d:\d\d(?::\d\d)?(?:\.\d+)?(?:Z|[+-]\d\d:?\d\d)?)\b/i,
  /\b(?:try again at|resets? at|resets?)\s+([0-9]{1,2}:[0-9]{2}\s*(?:am|pm)?\s*(?:pt|pst|pdt)?)\b/i,
];

function parseTime(raw) {
  if (/^[0-9]+$/.test(raw)) return nowEpoch + Number(raw);
  const iso = Date.parse(raw);
  if (Number.isFinite(iso)) return Math.floor(iso / 1000);
  const m = raw.match(/([0-9]{1,2}):([0-9]{2})\s*(am|pm)?/i);
  if (!m) return 0;
  let hour = Number(m[1]);
  const minute = Number(m[2]);
  const ampm = (m[3] || "").toLowerCase();
  if (ampm === "pm" && hour < 12) hour += 12;
  if (ampm === "am" && hour === 12) hour = 0;
  if (hour > 23 || minute > 59) return 0;
  const d = new Date(now.getTime());
  d.setHours(hour, minute, 0, 0);
  if (Math.floor(d.getTime() / 1000) <= nowEpoch) {
    d.setDate(d.getDate() + 1);
  }
  return Math.floor(d.getTime() / 1000);
}

for (const re of candidates) {
  const m = text.match(re);
  if (!m) continue;
  const raw = m[1].trim();
  const epoch = parseTime(raw);
  if (epoch > 0) {
    console.log(`reset_at=${/^[0-9]+$/.test(raw) ? `retry-after:${raw}s` : raw}`);
    console.log(`reset_epoch=${epoch}`);
    process.exit(0);
  }
}
NODE
}

fm_capacity_classify_text() {  # <text>
  local text=$1 lower class reason reset_fields reset_epoch now ttl provider model
  lower=$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')
  class=other
  reason=unclassified

  case "$lower" in
    *auth_unavailable*no\ auth\ available*)
      class=auth
      reason=proxy_auth_unavailable
      ;;
    *unknown\ provider\ for\ model*)
      class=other
      reason=proxy_unknown_model
      ;;
    *session\ limit*reset*)
      class=quota
      reason=claude_session_limit
      ;;
    *usage\ limit*try\ again*|*usage\ limit*reset*|*usage\ cap*reset*)
      class=quota
      reason=codex_usage_limit
      ;;
    *rate\ limit*not\ your\ usage\ limit*)
      class=other
      reason=transient_rate_limit
      ;;
    *rate\ limit*|*429\ too\ many\ requests*|*too\ many\ requests*)
      class=quota
      reason=rate_limit
      ;;
    *not\ logged\ in*|*please\ run\ /login*|*login\ required*)
      class=auth
      reason=login_required
      ;;
    *unauthorized*|*authentication*|*forbidden*)
      class=auth
      reason=auth_error
      ;;
  esac

  printf 'class=%s\nreason=%s\n' "$class" "$reason"
  case "$reason" in
    proxy_auth_unavailable)
      provider=$(printf '%s\n' "$text" | sed -n 's/.*providers=\([^,)]*\).*/\1/p' | head -1)
      model=$(printf '%s\n' "$text" | sed -n 's/.*model=\([^)]*\).*/\1/p' | head -1)
      [ -z "$provider" ] || printf 'provider=%s\n' "$provider"
      [ -z "$model" ] || printf 'model=%s\n' "$model"
      ;;
    login_required)
      provider=$(printf '%s\n' "$text" | sed -n 's/.*provider \([A-Za-z0-9_.@:-]*\).*/\1/p' | head -1)
      [ -z "$provider" ] || printf 'provider=%s\n' "$provider"
      ;;
  esac
  reset_fields=$(fm_capacity_reset_fields "$text")
  if [ -n "$reset_fields" ]; then
    printf '%s\n' "$reset_fields"
    reset_epoch=$(printf '%s\n' "$reset_fields" | sed -n 's/^reset_epoch=//p' | tail -1)
    now=$(fm_capacity_now_epoch)
    if [ -n "$reset_epoch" ] && [ "$reset_epoch" -gt "$now" ] 2>/dev/null; then
      ttl=$((reset_epoch - now))
      printf 'cooldown_ttl_secs=%s\n' "$ttl"
    fi
  fi
}

fm_capacity_safe_fragment() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_.@:-' '_'
}

fm_capacity_key_hash() {  # <harness> <account> <profile>
  printf '%s\t%s\t%s' "$1" "$2" "$3" | cksum | awk '{print $1}'
}

fm_capacity_cooldown_dir() {  # <state-dir>
  printf '%s/capacity-cooldowns\n' "$1"
}

fm_capacity_cooldown_file() {  # <state-dir> <harness> <account> <profile>
  local state=$1 harness=$2 account=$3 profile=$4 hash safe_harness
  hash=$(fm_capacity_key_hash "$harness" "$account" "$profile")
  safe_harness=$(fm_capacity_safe_fragment "$harness")
  printf '%s/%s-%s.env\n' "$(fm_capacity_cooldown_dir "$state")" "$safe_harness" "$hash"
}

fm_capacity_write_atomic() {  # <path> <content>
  local path=$1 content=$2 dir tmp old_umask
  dir=$(dirname "$path")
  mkdir -p "$dir"
  old_umask=$(umask)
  umask 077
  tmp=$(mktemp "$dir/.tmp.XXXXXXXX") || { umask "$old_umask"; return 1; }
  umask "$old_umask"
  printf '%s\n' "$content" > "$tmp"
  mv "$tmp" "$path"
}

fm_capacity_mark_cooldown() {
  local state=$1 harness=$2 account=$3 profile=$4 reset_epoch=$5 class=$6 reason=$7 source_task=${8:-}
  local now file created content key
  now=$(fm_capacity_now_epoch)
  case "$reset_epoch" in
    ''|*[!0-9]*) echo "error: reset epoch must be numeric" >&2; return 2 ;;
  esac
  if [ "$reset_epoch" -le "$now" ]; then
    echo "error: reset epoch is not in the future" >&2
    return 2
  fi
  file=$(fm_capacity_cooldown_file "$state" "$harness" "$account" "$profile")
  created=$(fm_capacity_iso_now)
  key=$(printf '%s/%s/%s' "$harness" "${account:-default}" "${profile:-default}")
  content=$(cat <<EOF
schema=fm-capacity-cooldown.v1
key=$key
harness=$harness
account=$account
profile=$profile
class=$class
reason=$reason
created_at=$created
created_epoch=$now
reset_epoch=$reset_epoch
source_task=$source_task
EOF
)
  fm_capacity_write_atomic "$file" "$content"
  printf '%s\n' "$file"
}

fm_capacity_mark_exhaustion() {
  local state=$1 harness=$2 account=$3 profile=$4 class=$5 reason=$6 source_task=${7:-} action=${8:-interactive_auth_required}
  local now file created content key
  now=$(fm_capacity_now_epoch)
  file=$(fm_capacity_cooldown_file "$state" "$harness" "$account" "$profile")
  created=$(fm_capacity_iso_now)
  key=$(printf '%s/%s/%s' "$harness" "${account:-default}" "${profile:-default}")
  content=$(cat <<EOF
schema=fm-capacity-cooldown.v1
key=$key
harness=$harness
account=$account
profile=$profile
class=$class
reason=$reason
created_at=$created
created_epoch=$now
reset_epoch=manual
requires_action=$action
source_task=$source_task
EOF
)
  fm_capacity_write_atomic "$file" "$content"
  printf '%s\n' "$file"
}

fm_capacity_cooldown_active() {  # <state-dir> <harness> <account> <profile>
  local state=$1 harness=$2 account=$3 profile=$4 file reset_epoch now remaining
  file=$(fm_capacity_cooldown_file "$state" "$harness" "$account" "$profile")
  [ -f "$file" ] || return 1
  reset_epoch=$(sed -n 's/^reset_epoch=//p' "$file" | tail -1)
  if [ "$reset_epoch" = manual ]; then
    cat "$file"
    printf 'remaining_secs=manual\n'
    return 0
  fi
  case "$reset_epoch" in
    ''|*[!0-9]*)
      rm -f "$file"
      return 1
      ;;
  esac
  now=$(fm_capacity_now_epoch)
  if [ "$reset_epoch" -le "$now" ]; then
    rm -f "$file"
    return 1
  fi
  remaining=$((reset_epoch - now))
  cat "$file"
  printf 'remaining_secs=%s\n' "$remaining"
}

fm_capacity_cooldown_active_for_route() {  # <state-dir> <harness> <account> <profile>
  local state=$1 harness=$2 account=$3 profile=$4 dir file rec_harness rec_account rec_profile
  if fm_capacity_cooldown_active "$state" "$harness" "$account" "$profile"; then
    return 0
  fi
  dir=$(fm_capacity_cooldown_dir "$state")
  [ -d "$dir" ] || return 1
  for file in "$dir"/*.env; do
    [ -f "$file" ] || continue
    rec_harness=$(sed -n 's/^harness=//p' "$file" | tail -1)
    [ "$rec_harness" = "$harness" ] || continue
    rec_account=$(sed -n 's/^account=//p' "$file" | tail -1)
    rec_profile=$(sed -n 's/^profile=//p' "$file" | tail -1)
    [ -z "$rec_account" ] || [ -z "$rec_profile" ] || [ "$rec_profile" = default ] || continue
    fm_capacity_cooldown_active "$state" "$rec_harness" "$rec_account" "$rec_profile" && return 0
  done
  return 1
}

fm_capacity_opposite_harness_ok() {  # <meta-file> <candidate-harness>
  local meta=$1 candidate=$2 forbidden
  [ -f "$meta" ] || return 0
  forbidden=$(grep '^opposite_harness_must_differ_from=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  [ -n "$forbidden" ] || return 0
  if [ "$candidate" = "$forbidden" ]; then
    echo "error: candidate harness '$candidate' violates opposite_harness_must_differ_from=$forbidden in $meta" >&2
    return 1
  fi
  return 0
}
