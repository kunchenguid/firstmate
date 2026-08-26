#!/usr/bin/env bash
# Persistent Firstmate home and task identities.
#
# Current callsigns are the only names that reserve a pool entry. Archived
# records and retired_callsign history are retained as evidence but ignored by
# allocation and selector resolution.

FM_IDENTITY_DATA=${FM_IDENTITY_DATA:-${FM_DATA_OVERRIDE:-${DATA:-${FM_HOME:-.}/data}}}
FM_IDENTITY_STATE=${FM_IDENTITY_STATE:-${FM_STATE_OVERRIDE:-${STATE:-${FM_HOME:-.}/state}}}
FM_IDENTITY_HOME_POOL="Rayleigh Beckman Zoro Killer Marco King Shiryu Lafitte Daz Gin Mohji Cabaji Jango Pearl Sarquiss"
FM_IDENTITY_SECOND_MATE_POOL="Jinbei Katakuri Sabo Law Vivi Yamato Hancock Mihawk Crocodile Dragon Shanks Kuma Ace Smoker Fujitora Garp Sengoku Tsuru Kuzan Kizaru Ryokugyu Magellan Hannyabal Kyros Neptune Momonosuke Kinemon Denjiro Inuarashi Nekomamushi Bonney Urouge Capone Hawkins Drake Apoo"
FM_IDENTITY_CREWMATE_POOL="Franky Robin Nami Sanji Usopp Brook Chopper Koby Tashigi Perona Reiju Pudding Carrot Bepo Penguin Shachi Heat Wire Bartolomeo Cavendish Rebecca Viola Leo Sai Ideo Hajrudin Orlumbus Chinjao Bellamy BonClay Galdino Baby5 Koala Hack Inazuma Karasu Lindbergh Morley BeloBetty Helmeppo Hina Fullbody Sentomaru Momonga Doberman Onigumo Bastille Bogard Raizo Kikunojo Ashura Kawamatsu Izo Shinobu Tama Toko Hiyori Mansherry Dellinger SenorPink Pica Diamante Trebol Sugar Ichiji Niji Yonji Pekoms Tamago Chiffon Lola Praline Brulee Cracker Smoothie Oven Daifuku Perospero Nojiko Genzo Zeff Patty Carne Kaya Merry Makino Laboon Crocus Dorry Brogy Dalton Kureha GanFall Conis Wyper Aisa Paulie Iceburg Kokoro Chimney Camie Hachi Duval Shirahoshi Fukaboshi Ryuboshi Manboshi Otohime Aladine Shaka Lilith Pythagoras Atlas York"
FM_IDENTITY_RESERVED_NAMES="luffy roger captain firstmate first-mate mate crew crewmate secondmate second-mate scout ship default unknown unnamed archived active provisioning"

fm_identity_error() {
  echo "error: $*" >&2
}

fm_identity_fold() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

fm_identity_task_record() {
  printf '%s/crew-identities/%s.identity\n' "$FM_IDENTITY_DATA" "$1"
}

fm_identity_record_value() {
  local record=$1 key=$2
  sed -n "s/^${key}=//p" "$record" | head -1
}

fm_identity_meta_value() {
  fm_identity_record_value "$1" "$2"
}

fm_identity_name_valid() {
  [[ "$1" =~ ^[A-Za-z][A-Za-z0-9-]{1,31}$ ]]
}

fm_identity_task_id_valid() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]
}

fm_identity_value_safe() {
  case "$1" in *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac
}

fm_identity_validate_name() {
  local folded
  fm_identity_name_valid "$1" || {
    fm_identity_error "callsign '$1' must be 2-32 characters, start with a letter, and contain only letters, digits, or hyphens"
    return 1
  }
  fm_identity_value_safe "$1" || return 1
  folded=$(fm_identity_fold "$1")
  case " $FM_IDENTITY_RESERVED_NAMES " in *" $folded "*)
    fm_identity_error "callsign '$1' is reserved"
    return 1
    ;;
  esac
}

fm_identity_prepare_dirs() {
  mkdir -p "$FM_IDENTITY_DATA/crew-identities" "$FM_IDENTITY_STATE"
}

fm_identity_lock_acquire() {
  local lock="$FM_IDENTITY_DATA/.identity.lock" tries=0
  mkdir -p "$FM_IDENTITY_DATA"
  while ! mkdir "$lock" 2>/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -lt 500 ] || return 1
    sleep 0.01
  done
}

fm_identity_lock_release() {
  rmdir "$FM_IDENTITY_DATA/.identity.lock" 2>/dev/null || true
}

fm_identity_checksum() {
  local value=$1 sum=0 byte i
  LC_ALL=C
  for ((i=0; i<${#value}; i++)); do
    printf -v byte '%d' "'${value:i:1}"
    sum=$(((sum * 33 + byte) & 2147483647))
  done
  printf '%s\n' "$sum"
}

fm_identity_pool_for_kind() {
  case "${1:-ship}" in
    firstmate|home|firstmate-home) printf '%s\n' "$FM_IDENTITY_HOME_POOL" ;;
    secondmate) printf '%s\n' "$FM_IDENTITY_SECOND_MATE_POOL" ;;
    *) printf '%s\n' "$FM_IDENTITY_CREWMATE_POOL" ;;
  esac
}

fm_identity_pool_item() {
  local pool=$1 wanted=$2 item index=0
  for item in $pool; do
    [ "$index" -eq "$wanted" ] && { printf '%s\n' "$item"; return 0; }
    index=$((index + 1))
  done
  return 1
}

fm_identity_pool_size() {
  local pool=$1 item count=0
  for item in $pool; do count=$((count + 1)); done
  printf '%s\n' "$count"
}

fm_identity_status_live() {
  case "$1" in provisioning|active) return 0 ;; *) return 1 ;; esac
}

fm_identity_live_names() {
  local home_record="$FM_IDENTITY_DATA/firstmate.identity" record records=()
  [ -f "$home_record" ] && records+=("$home_record")
  for record in "$FM_IDENTITY_DATA"/crew-identities/*.identity; do
    [ -f "$record" ] && records+=("$record")
  done
  [ "${#records[@]}" -gt 0 ] || return 0
  awk -F= '
    FILENAME ~ /firstmate\.identity$/ && $1 == "name" { home=$2 }
    FILENAME ~ /crew-identities\/.*\.identity$/ {
      file=FILENAME
      sub(/^.*\//, "", file)
      sub(/\.identity$/, "", file)
      if ($1 == "status") status[file]=tolower($2)
      if ($1 == "callsign") callsign[file]=$2
    }
    END {
      if (home != "") print home "\t"
      for (file in status) {
        if (status[file] == "active" || status[file] == "provisioning")
          print callsign[file] "\t" file
      }
    }
  ' "${records[@]}"
}

fm_identity_live_name_in_list() {
  local wanted=$1 names=$2 ignore=${3:-} name id wanted_fold
  wanted_fold=$(fm_identity_fold "$wanted")
  while IFS=$'\t' read -r name id; do
    [ "$id" = "$ignore" ] && continue
    [ "$(fm_identity_fold "$name")" = "$wanted_fold" ] && return 0
    [ "$(fm_identity_fold "$id")" = "$wanted_fold" ] && return 0
  done <<< "$names"
  return 1
}

fm_identity_name_in_use() {
  local wanted=$1 ignore=${2:-} wanted_fold names
  wanted_fold=$(fm_identity_fold "$wanted")
  [ "$wanted_fold" != luffy ] || return 0
  [ "$wanted_fold" != roger ] || return 0
  names=$(fm_identity_live_names)
  fm_identity_live_name_in_list "$wanted" "$names" "$ignore"
}

fm_identity_choose_fresh_callsign() {
  local id=$1 kind=${2:-ship} pool size checksum start offset base suffix candidate live_names
  pool=$(fm_identity_pool_for_kind "$kind")
  size=$(fm_identity_pool_size "$pool")
  [ "$size" -gt 0 ] || return 1
  checksum=$(fm_identity_checksum "$id")
  start=$((checksum % size))
  live_names=$(fm_identity_live_names)
  for ((offset=0; offset<size; offset++)); do
    base=$(fm_identity_pool_item "$pool" "$(((start + offset) % size))")
    fm_identity_live_name_in_list "$base" "$live_names" || { printf '%s\n' "$base"; return 0; }
  done
  base=$(fm_identity_pool_item "$pool" "$start")
  suffix=2
  while :; do
    candidate="$base-$suffix"
    fm_identity_live_name_in_list "$candidate" "$live_names" || { printf '%s\n' "$candidate"; return 0; }
    suffix=$((suffix + 1))
  done
}

fm_identity_legacy_callsign() {
  fm_identity_choose_fresh_callsign "$1" "${2:-ship}"
}

fm_identity_write_task_record() {
  local record=$1 id=$2 callsign=$3 status=$4 meta=${5:-} created=${6:-} old=${7:-} tmp
  fm_identity_task_id_valid "$id" && fm_identity_validate_name "$callsign" >/dev/null
  fm_identity_value_safe "$id" && fm_identity_value_safe "$meta" || return 1
  [ -n "$created" ] || created=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  tmp="$record.tmp.${BASHPID:-$$}"
  {
    printf 'schema=fm-crew-identity.v1\n'
    printf 'home=%s\n' "$(cd "$FM_IDENTITY_DATA/.." && pwd -P)"
    printf 'task_id=%s\n' "$id"
    printf 'callsign=%s\n' "$callsign"
    printf 'status=%s\n' "$status"
    [ -z "$meta" ] || {
      printf 'worktree=%s\n' "$(fm_identity_meta_value "$meta" worktree)"
      printf 'backend=%s\n' "$(fm_identity_meta_value "$meta" backend)"
      printf 'endpoint=%s\n' "$(fm_identity_meta_value "$meta" window)"
      printf 'endpoint_session_id=%s\n' "$(fm_identity_meta_value "$meta" herdr_session)"
      printf 'harness_session_id=%s\n' "$(fm_identity_meta_value "$meta" codex_session_id)"
      printf 'spawn_gen=%s\n' "$(fm_identity_meta_value "$meta" spawn_gen)"
    }
    printf 'created_at=%s\nupdated_at=%s\n' "$created" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    [ -z "$old" ] || printf 'retired_callsign=%s\n' "$old"
  } > "$tmp"
  mv -f -- "$tmp" "$record"
}

fm_identity_reserve_fresh_task() {
  local id=$1 kind=${2:-ship} record callsign status
  fm_identity_prepare_dirs
  fm_identity_task_id_valid "$id" || return 1
  fm_identity_lock_acquire || return 1
  record=$(fm_identity_task_record "$id")
  if [ -f "$record" ]; then
    status=$(fm_identity_record_value "$record" status)
    callsign=$(fm_identity_record_value "$record" callsign)
    if [ "$status" = provisioning ] && [ ! -f "$FM_IDENTITY_STATE/$id.meta" ]; then
      fm_identity_lock_release
      printf '%s\n' "$callsign"
      return 0
    fi
    fm_identity_lock_release
    fm_identity_error "task id '$id' already has a $status identity; refusing a fresh assignment"
    return 1
  fi
  if ! callsign=$(fm_identity_choose_fresh_callsign "$id" "$kind"); then
    fm_identity_lock_release
    return 1
  fi
  if ! fm_identity_write_task_record "$record" "$id" "$callsign" provisioning; then
    fm_identity_lock_release
    return 1
  fi
  fm_identity_lock_release
  printf '%s\n' "$callsign"
}

fm_identity_activate_reserved_task_from_meta() {
  local meta=$1 id=$2 record callsign status created
  record=$(fm_identity_task_record "$id")
  [ -f "$record" ] || return 1
  status=$(fm_identity_record_value "$record" status)
  [ "$status" = provisioning ] || return 1
  callsign=$(fm_identity_record_value "$record" callsign)
  created=$(fm_identity_record_value "$record" created_at)
  fm_identity_write_task_record "$record" "$id" "$callsign" active "$meta" "$created"
  printf '%s\n' "$callsign"
}

fm_identity_ensure_task_from_meta() {
  local meta=$1 id=$2 record callsign status created kind
  [ -f "$meta" ] || return 1
  fm_identity_prepare_dirs
  record=$(fm_identity_task_record "$id")
  if [ -f "$record" ]; then
    status=$(fm_identity_record_value "$record" status)
    callsign=$(fm_identity_record_value "$record" callsign)
    [ "$status" != archived ] || return 1
    created=$(fm_identity_record_value "$record" created_at)
    fm_identity_write_task_record "$record" "$id" "$callsign" active "$meta" "$created"
    printf '%s\n' "$callsign"
    return 0
  fi
  kind=$(fm_identity_meta_value "$meta" kind)
  callsign=$(fm_identity_choose_fresh_callsign "$id" "$kind") || return 1
  fm_identity_write_task_record "$record" "$id" "$callsign" active "$meta"
  printf '%s\n' "$callsign"
}

fm_identity_ensure_legacy_archive() {
  local id=$1 record callsign kind
  record=$(fm_identity_task_record "$id")
  [ -f "$record" ] && { fm_identity_record_value "$record" callsign; return 0; }
  kind=ship
  [ -f "$FM_IDENTITY_STATE/$id.meta" ] && kind=$(fm_identity_meta_value "$FM_IDENTITY_STATE/$id.meta" kind)
  callsign=$(fm_identity_choose_fresh_callsign "$id" "$kind") || return 1
  fm_identity_write_task_record "$record" "$id" "$callsign" archived
  printf '%s\n' "$callsign"
}

fm_identity_archive_task() {
  local meta=$1 id=$2 record callsign created
  record=$(fm_identity_task_record "$id")
  [ -f "$record" ] || return 1
  callsign=$(fm_identity_record_value "$record" callsign)
  created=$(fm_identity_record_value "$record" created_at)
  fm_identity_write_task_record "$record" "$id" "$callsign" archived "$meta" "$created"
  printf '%s\n' "$callsign"
}

fm_identity_display_callsign() {
  local id=$1 record
  record=$(fm_identity_task_record "$id")
  if [ -f "$record" ]; then fm_identity_record_value "$record" callsign; else fm_identity_legacy_callsign "$id"; fi
}

fm_identity_resolve_selector() {
  local state=$1 raw=$2 record id status callsign match=
  case "$raw" in *:*) fm_identity_error "selector '$raw' is an endpoint, not a callsign or task id"; return 1 ;; esac
  if fm_identity_task_id_valid "$raw" && [ -f "$state/$raw.meta" ]; then
    record=$(fm_identity_task_record "$raw")
    if [ ! -f "$record" ] || fm_identity_status_live "$(fm_identity_record_value "$record" status)"; then
      printf '%s\n' "$raw"
      return 0
    fi
  fi
  for record in "$FM_IDENTITY_DATA"/crew-identities/*.identity; do
    [ -f "$record" ] || continue
    status=$(fm_identity_record_value "$record" status)
    fm_identity_status_live "$status" || continue
    callsign=$(fm_identity_record_value "$record" callsign)
    if [ "$(fm_identity_fold "$callsign")" = "$(fm_identity_fold "$raw")" ]; then
      id=$(basename "$record" .identity)
      [ -z "$match" ] || { fm_identity_error "callsign '$raw' is ambiguous across live identities"; return 1; }
      match=$id
    fi
  done
  [ -n "$match" ] || { fm_identity_error "no live callsign or task '$raw' exists"; return 1; }
  printf '%s\n' "$match"
}

fm_identity_rename_task() {
  local state=$1 selector=$2 new=$3 id record old created
  id=$(fm_identity_resolve_selector "$state" "$selector") || return 1
  record=$(fm_identity_task_record "$id")
  [ "$(fm_identity_record_value "$record" status)" = active ] || return 1
  fm_identity_validate_name "$new" || return 1
  fm_identity_name_in_use "$new" "$id" && {
    fm_identity_error "callsign '$new' is already owned by a live identity"
    return 1
  }
  old=$(fm_identity_record_value "$record" callsign)
  created=$(fm_identity_record_value "$record" created_at)
  fm_identity_write_task_record "$record" "$id" "$new" active "$state/$id.meta" "$created" "$old"
  printf '%s\t%s\n' "$new" "$id"
}

fm_identity_ensure_home() {
  local record="$FM_IDENTITY_DATA/firstmate.identity" name checksum size index offset candidate suffix live_names
  fm_identity_prepare_dirs
  if [ -f "$record" ]; then fm_identity_record_value "$record" name; return 0; fi
  size=$(fm_identity_pool_size "$FM_IDENTITY_HOME_POOL")
  checksum=$(fm_identity_checksum "$(cd "$FM_IDENTITY_DATA/.." && pwd -P)")
  index=$((checksum % size))
  live_names=$(fm_identity_live_names)
  for ((offset=0; offset<size; offset++)); do
    candidate=$(fm_identity_pool_item "$FM_IDENTITY_HOME_POOL" "$(((index + offset) % size))")
    fm_identity_live_name_in_list "$candidate" "$live_names" || { name=$candidate; break; }
  done
  if [ -z "$name" ]; then
    name=$(fm_identity_pool_item "$FM_IDENTITY_HOME_POOL" "$index")
    suffix=2
    while fm_identity_live_name_in_list "$name-$suffix" "$live_names"; do suffix=$((suffix + 1)); done
    name="$name-$suffix"
  fi
  {
    printf 'schema=fm-firstmate-identity.v1\n'
    printf 'home=%s\n' "$(cd "$FM_IDENTITY_DATA/.." && pwd -P)"
    printf 'name=%s\ncreated_at=%s\nupdated_at=%s\n' "$name" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  } > "$record"
  printf '%s\n' "$name"
}

fm_identity_rename_home() {
  local new=$1 record="$FM_IDENTITY_DATA/firstmate.identity" old
  fm_identity_validate_name "$new" || return 1
  fm_identity_name_in_use "$new" && return 1
  old=$(fm_identity_ensure_home)
  sed "s/^name=.*/name=$new/" "$record" > "$record.tmp.${BASHPID:-$$}"
  mv -f -- "$record.tmp.${BASHPID:-$$}" "$record"
  printf '%s\n' "$new"
  : "$old"
}

fm_identity_history() {
  local record id callsign status
  for record in "$FM_IDENTITY_DATA"/crew-identities/*.identity; do
    [ -f "$record" ] || continue
    id=$(basename "$record" .identity)
    callsign=$(fm_identity_record_value "$record" callsign)
    status=$(fm_identity_record_value "$record" status)
    printf '%s\t%s\t%s\n' "$callsign" "$id" "$status"
  done
}
