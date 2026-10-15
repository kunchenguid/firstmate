# shellcheck shell=bash
# Load-profile registry. Session start asks this file what to run.
# Usage: . bin/fm-load-profile-lib.sh
#
# Profiles name digest stages only. Binding one does not disable Pi primary
# extensions and does not add skill files to the always-on prefix.
#
# ponytail: FM_LOAD_PROFILES_TSV points bind at another table.
# Ceiling: a bad path fails the bind. Upgrade path: a second product table, if one is ever real.
#
# ponytail: one byte cap covers the whole slim digest, including identity fleet.
# Ceiling: one stage can spend the whole cap. Upgrade path: per-stage caps in the table.

_FM_LP_READY=0
_FM_LP_ID=
_FM_LP_SOURCE=
_FM_LP_DIAG=
_FM_LP_SLOTS=
_FM_LP_STAGE=()
_FM_LP_POLICY=()
_FM_LP_RAW_S_STAGE=()
_FM_LP_RAW_S_POLICY=()
_FM_LP_RAW_S_TIMEOUT=
_FM_LP_RAW_S_SLOTS=
_FM_LP_RAW_F_STAGE=()
_FM_LP_RAW_F_POLICY=()
_FM_LP_RAW_F_TIMEOUT=
_FM_LP_RAW_F_SLOTS=
_FM_LP_TAIL=
_FM_LP_QUEUED=
_FM_LP_ENDPOINT=
_FM_LP_SLIM_MAX_BYTES=24576

_fm_lp_die() {
  printf 'fm-load-profile: %s\n' "$*" >&2
  return 1
}

_fm_lp_clear_raw() {
  _FM_LP_RAW_S_STAGE=()
  _FM_LP_RAW_S_POLICY=()
  _FM_LP_RAW_S_TIMEOUT=
  _FM_LP_RAW_S_SLOTS=
  _FM_LP_RAW_F_STAGE=()
  _FM_LP_RAW_F_POLICY=()
  _FM_LP_RAW_F_TIMEOUT=
  _FM_LP_RAW_F_SLOTS=
}

_fm_lp_clear() {
  _FM_LP_READY=0
  _FM_LP_ID=
  _FM_LP_SOURCE=
  _FM_LP_DIAG=
  _FM_LP_SLOTS=
  _FM_LP_STAGE=()
  _FM_LP_POLICY=()
  _fm_lp_clear_raw
}

_fm_lp_tsv_path() {
  if [ -n "${FM_LOAD_PROFILES_TSV:-}" ]; then
    printf '%s\n' "$FM_LOAD_PROFILES_TSV"
    return 0
  fi
  local dir
  dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || return 1
  printf '%s\n' "$dir/fm-load-profiles.tsv"
}

_fm_lp_posint() {
  case "$1" in
    ''|*[!0-9]*|0*) return 1 ;;
  esac
}

_fm_lp_env_num() {
  local v=${!1-}
  _fm_lp_posint "$v" || return 1
  printf '%s\n' "$v"
}

_fm_lp_must_run() {
  case "$1" in
    lock|role|wake-queue|supervision-instructions|read-once|fleet-state|next-step)
      return 0
      ;;
  esac
  return 1
}

_fm_lp_known_stage() {
  case "$1" in
    lock|role|bootstrap|wake-queue|supervision-instructions|read-once|fleet-state|network-checks|context|next-step)
      return 0
      ;;
  esac
  return 1
}

_fm_lp_slots_all() {  # <pointer|body> <cap>
  local emit=$1 cap=$2 id
  for id in projects secondmates captain captain-shared learnings; do
    printf '%s\t%s\t%s\n' "$id" "$emit" "$cap"
  done
}

_fm_lp_slots_listed() {  # <extra>
  local extra=$1 rest=$1 item id spec emit cap
  local projects='' secondmates='' captain='' captain_shared='' learnings=''
  [ -n "$extra" ] || return 1
  while [ -n "$rest" ]; do
    item=${rest%%,*}
    case "$rest" in
      *,*) rest=${rest#*,} ;;
      *) rest= ;;
    esac
    id=${item%%=*}
    spec=${item#*=}
    [ "$id" != "$item" ] || return 1
    case "$spec" in
      pointer) emit=pointer cap=- ;;
      body:uncapped) emit=body cap=uncapped ;;
      body:*)
        cap=${spec#body:}
        _fm_lp_posint "$cap" || return 1
        emit=body
        ;;
      *) return 1 ;;
    esac
    case "$id" in
      projects) [ -z "$projects" ] || return 1; projects="$emit"$'\t'"$cap" ;;
      secondmates) [ -z "$secondmates" ] || return 1; secondmates="$emit"$'\t'"$cap" ;;
      captain) [ -z "$captain" ] || return 1; captain="$emit"$'\t'"$cap" ;;
      captain-shared) [ -z "$captain_shared" ] || return 1; captain_shared="$emit"$'\t'"$cap" ;;
      learnings) [ -z "$learnings" ] || return 1; learnings="$emit"$'\t'"$cap" ;;
      *) return 1 ;;
    esac
  done
  [ -n "$projects" ] && [ -n "$secondmates" ] && [ -n "$captain" ] \
    && [ -n "$captain_shared" ] && [ -n "$learnings" ] || return 1
  printf '%s\t%s\n' projects "$projects"
  printf '%s\t%s\n' secondmates "$secondmates"
  printf '%s\t%s\n' captain "$captain"
  printf '%s\t%s\n' captain-shared "$captain_shared"
  printf '%s\t%s\n' learnings "$learnings"
}

_fm_lp_parse_full_extra() {  # <extra>
  local extra=$1 rest a b c
  case "$extra" in
    full:*) ;;
    *) return 1 ;;
  esac
  rest=${extra#full:}
  case "$rest" in
    *,*,*,*) return 1 ;;
    *,*,*) ;;
    *) return 1 ;;
  esac
  a=${rest%%,*}
  rest=${rest#*,}
  b=${rest%%,*}
  c=${rest#*,}
  case "$a" in
    tail=*) _FM_LP_TAIL=${a#tail=} ;;
    *) return 1 ;;
  esac
  case "$b" in
    queued=*) _FM_LP_QUEUED=${b#queued=} ;;
    *) return 1 ;;
  esac
  case "$c" in
    endpoint=*) _FM_LP_ENDPOINT=${c#endpoint=} ;;
    *) return 1 ;;
  esac
  _fm_lp_posint "$_FM_LP_TAIL" || return 1
  _fm_lp_posint "$_FM_LP_QUEUED" || return 1
  _fm_lp_posint "$_FM_LP_ENDPOINT" || return 1
}

_fm_lp_note_timeout() {  # <s|f> <seconds>
  local which=$1 v=$2 cur
  if [ "$which" = s ]; then
    cur=$_FM_LP_RAW_S_TIMEOUT
  else
    cur=$_FM_LP_RAW_F_TIMEOUT
  fi
  if [ -z "$cur" ]; then
    if [ "$which" = s ]; then
      _FM_LP_RAW_S_TIMEOUT=$v
    else
      _FM_LP_RAW_F_TIMEOUT=$v
    fi
    return 0
  fi
  [ "$cur" = "$v" ]
}

_fm_lp_seen_stage() {  # <s|f> <stage>
  local which=$1 stage=$2 i n cur
  if [ "$which" = s ]; then
    n=${#_FM_LP_RAW_S_STAGE[@]}
  else
    n=${#_FM_LP_RAW_F_STAGE[@]}
  fi
  i=0
  while [ "$i" -lt "$n" ]; do
    if [ "$which" = s ]; then
      cur=${_FM_LP_RAW_S_STAGE[$i]}
    else
      cur=${_FM_LP_RAW_F_STAGE[$i]}
    fi
    [ "$cur" = "$stage" ] && return 0
    i=$((i + 1))
  done
  return 1
}

_fm_lp_add() {  # <s|f> <stage> <policy> <slots>
  local which=$1 stage=$2 policy=$3 slots=$4 n
  if _fm_lp_seen_stage "$which" "$stage"; then
    _fm_lp_die "duplicate stage $stage" || return 1
  fi
  if [ "$which" = s ]; then
    n=${#_FM_LP_RAW_S_STAGE[@]}
    _FM_LP_RAW_S_STAGE[n]=$stage
    _FM_LP_RAW_S_POLICY[n]=$policy
    if [ "$stage" = context ]; then
      _FM_LP_RAW_S_SLOTS=$slots
    fi
  else
    n=${#_FM_LP_RAW_F_STAGE[@]}
    _FM_LP_RAW_F_STAGE[n]=$stage
    _FM_LP_RAW_F_POLICY[n]=$policy
    if [ "$stage" = context ]; then
      _FM_LP_RAW_F_SLOTS=$slots
    fi
  fi
}

_fm_lp_row() {  # profile stage run emit extra timeout
  local profile=$1 stage=$2 run=$3 emit=$4 extra=$5 timeout=$6
  local which policy slots=
  case "$profile" in
    slim) which=s ;;
    full) which=f ;;
    *) _fm_lp_die "unknown profile $profile" || return 1 ;;
  esac
  _fm_lp_known_stage "$stage" || { _fm_lp_die "unknown stage $stage" || return 1; }
  case "$run" in
    yes|no) ;;
    *) _fm_lp_die "invalid run for $stage" || return 1 ;;
  esac
  case "$emit" in
    body|pointer|slots) ;;
    *) _fm_lp_die "invalid emit for $stage" || return 1 ;;
  esac
  _fm_lp_posint "$timeout" || { _fm_lp_die "invalid session_timeout_sec" || return 1; }
  _fm_lp_note_timeout "$which" "$timeout" \
    || { _fm_lp_die "session_timeout_sec disagrees in profile $profile" || return 1; }
  if [ "$run" = no ] && [ "$emit" != pointer ]; then
    _fm_lp_die "run=no emit=$emit" || return 1
  fi
  if [ "$run" = no ] && _fm_lp_must_run "$stage"; then
    _fm_lp_die "stage $stage must run" || return 1
  fi
  case "$stage" in
    fleet-state)
      case "$emit" in
        pointer)
          [ -z "$extra" ] || { _fm_lp_die "invalid fleet extra" || return 1; }
          policy="run=$run emit=pointer"
          ;;
        body)
          case "$extra" in
            identity)
              policy='run=yes emit=body depth=identity'
              ;;
            full:*)
              _fm_lp_parse_full_extra "$extra" \
                || { _fm_lp_die "fleet full depth needs tail, queued, and endpoint" || return 1; }
              policy="run=yes emit=body depth=full tail=${_FM_LP_TAIL} queued=${_FM_LP_QUEUED} endpoint=${_FM_LP_ENDPOINT}"
              ;;
            *tail*|*queued*|*endpoint*)
              _fm_lp_die "identity fleet cannot carry tail, queued, or endpoint" || return 1
              ;;
            *)
              _fm_lp_die "invalid fleet extra" || return 1
              ;;
          esac
          ;;
        *)
          _fm_lp_die "invalid emit for fleet-state" || return 1
          ;;
      esac
      ;;
    context)
      case "$emit" in
        pointer)
          [ -z "$extra" ] || { _fm_lp_die "invalid context extra" || return 1; }
          policy="run=$run emit=pointer"
          ;;
        slots)
          case "$extra" in
            all=pointer)
              slots=$(_fm_lp_slots_all pointer -) || return 1
              ;;
            all=body:uncapped)
              slots=$(_fm_lp_slots_all body uncapped) || return 1
              ;;
            all=body:*)
              _fm_lp_posint "${extra#all=body:}" \
                || { _fm_lp_die "context slots are not a total memory map" || return 1; }
              slots=$(_fm_lp_slots_all body "${extra#all=body:}") || return 1
              ;;
            *)
              slots=$(_fm_lp_slots_listed "$extra") \
                || { _fm_lp_die "context slots are not a total memory map" || return 1; }
              ;;
          esac
          policy="run=$run emit=slots"
          ;;
        *)
          _fm_lp_die "invalid emit for context" || return 1
          ;;
      esac
      ;;
    *)
      case "$emit" in
        body|pointer) ;;
        *) _fm_lp_die "invalid emit for $stage" || return 1 ;;
      esac
      [ -z "$extra" ] || { _fm_lp_die "plain stage $stage has extra" || return 1; }
      policy="run=$run emit=$emit"
      ;;
  esac
  _fm_lp_add "$which" "$stage" "$policy" "$slots"
}

# Tab is IFS whitespace, so `read` would drop the empty extra column.
_fm_lp_split6() {  # <line>
  local rest=$1 i=0 part
  _FM_LP_F1='' _FM_LP_F2='' _FM_LP_F3='' _FM_LP_F4='' _FM_LP_F5='' _FM_LP_F6=''
  while [ "$i" -lt 5 ]; do
    case "$rest" in
      *$'\t'*) ;;
      *) return 1 ;;
    esac
    part=${rest%%$'\t'*}
    rest=${rest#*$'\t'}
    i=$((i + 1))
    case "$i" in
      1) _FM_LP_F1=$part ;;
      2) _FM_LP_F2=$part ;;
      3) _FM_LP_F3=$part ;;
      4) _FM_LP_F4=$part ;;
      5) _FM_LP_F5=$part ;;
    esac
  done
  case "$rest" in
    *$'\t'*) return 2 ;;
  esac
  _FM_LP_F6=$rest
}

_fm_lp_parse() {
  local tsv line header_seen=0 split
  _fm_lp_clear_raw
  tsv=$(_fm_lp_tsv_path) || return 1
  [ -f "$tsv" ] || { _fm_lp_die "missing profiles table" || return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in
      ''|\#*) continue ;;
    esac
    if [ "$header_seen" -eq 0 ]; then
      [ "$line" = $'profile\tstage\trun\temit\textra\tsession_timeout_sec' ] \
        || { _fm_lp_die "profiles table header is wrong" || return 1; }
      header_seen=1
      continue
    fi
    split=0
    _fm_lp_split6 "$line" || split=$?
    if [ "$split" -eq 1 ]; then
      _fm_lp_die "profiles row has too few fields" || return 1
    fi
    if [ "$split" -ne 0 ]; then
      _fm_lp_die "profiles row has too many fields" || return 1
    fi
    _fm_lp_row "$_FM_LP_F1" "$_FM_LP_F2" "$_FM_LP_F3" "$_FM_LP_F4" "$_FM_LP_F5" "$_FM_LP_F6" || return 1
  done <"$tsv"
  [ "$header_seen" -eq 1 ] || { _fm_lp_die "profiles table header is wrong" || return 1; }
  [ "${#_FM_LP_RAW_S_STAGE[@]}" -eq 10 ] \
    || { _fm_lp_die "profile slim does not cover every stage" || return 1; }
  [ "${#_FM_LP_RAW_F_STAGE[@]}" -eq 10 ] \
    || { _fm_lp_die "profile full does not cover every stage" || return 1; }
}

_fm_lp_apply_full_env() {  # <policy body>
  local body=$1 head rest tail queued endpoint
  case "$body" in
    *' depth=full tail='*) ;;
    *)
      printf '%s\n' "$body"
      return 0
      ;;
  esac
  head=${body%% depth=full tail=*}
  rest=${body#* depth=full tail=}
  tail=${rest%% queued=*}
  rest=${rest#*queued=}
  queued=${rest%% endpoint=*}
  endpoint=${rest#*endpoint=}
  if rest=$(_fm_lp_env_num FM_SESSION_START_STATUS_TAIL); then
    tail=$rest
  fi
  if rest=$(_fm_lp_env_num FM_SESSION_START_QUEUED_LIMIT); then
    queued=$rest
  fi
  if rest=$(_fm_lp_env_num FM_SESSION_START_ENDPOINT_TIMEOUT); then
    endpoint=$rest
  fi
  printf '%s depth=full tail=%s queued=%s endpoint=%s\n' "$head" "$tail" "$queued" "$endpoint"
}

_fm_lp_activate() {  # <s|f> <id> <source> <diagnostic>
  local which=$1 timeout n i body
  _FM_LP_ID=$2
  _FM_LP_SOURCE=$3
  _FM_LP_DIAG=$4
  _FM_LP_STAGE=()
  _FM_LP_POLICY=()
  if [ "$which" = s ]; then
    timeout=$_FM_LP_RAW_S_TIMEOUT
    n=${#_FM_LP_RAW_S_STAGE[@]}
    _FM_LP_SLOTS=$_FM_LP_RAW_S_SLOTS
  else
    timeout=$_FM_LP_RAW_F_TIMEOUT
    n=${#_FM_LP_RAW_F_STAGE[@]}
    _FM_LP_SLOTS=$_FM_LP_RAW_F_SLOTS
  fi
  if body=$(_fm_lp_env_num FM_SESSION_START_TIMEOUT); then
    timeout=$body
  fi
  i=0
  while [ "$i" -lt "$n" ]; do
    if [ "$which" = s ]; then
      _FM_LP_STAGE[i]=${_FM_LP_RAW_S_STAGE[$i]}
      body=${_FM_LP_RAW_S_POLICY[$i]}
    else
      _FM_LP_STAGE[i]=${_FM_LP_RAW_F_STAGE[$i]}
      body=${_FM_LP_RAW_F_POLICY[$i]}
    fi
    body=$(_fm_lp_apply_full_env "$body")
    _FM_LP_POLICY[i]="$body timeout=$timeout"
    i=$((i + 1))
  done
  _FM_LP_READY=1
}

_fm_lp_config_token() {  # <home>
  local cfg=$1/config/load-profile line count=0 token=
  _FM_LP_CFG_COUNT=0
  _FM_LP_CFG_TOKEN=
  [ -f "$cfg" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in
      *[![:space:]]*)
        count=$((count + 1))
        token=$line
        ;;
    esac
  done <"$cfg"
  _FM_LP_CFG_COUNT=$count
  _FM_LP_CFG_TOKEN=$token
}

fm_load_profile_bind() {  # <home> <harness> <backend>
  local home=${1-} harness=${2-} backend=${3-}
  local id='' source='' diag='' which=''
  _fm_lp_clear
  if [ -z "$home" ] || [ -z "$harness" ] || [ -z "$backend" ]; then
    _fm_lp_die "bind needs home, harness, and backend" || return 1
  fi
  _fm_lp_parse || return 1
  _fm_lp_config_token "$home" || return 1
  if [ "$_FM_LP_CFG_COUNT" -eq 1 ] \
    && { [ "$_FM_LP_CFG_TOKEN" = slim ] || [ "$_FM_LP_CFG_TOKEN" = full ]; }; then
    id=$_FM_LP_CFG_TOKEN
    source=config
  elif [ "$_FM_LP_CFG_COUNT" -gt 1 ]; then
    diag='load-profile config has more than one token'
  elif [ "$_FM_LP_CFG_COUNT" -eq 1 ]; then
    diag="unknown load-profile token: $_FM_LP_CFG_TOKEN"
  fi
  if [ -z "$id" ]; then
    case "$harness:$backend" in
      pi:herdr|pi-signed:herdr)
        id=slim
        source=default-pi-herdr
        ;;
      *)
        id=full
        source=default-other
        ;;
    esac
  fi
  if [ "$id" = slim ]; then
    which=s
  else
    which=f
  fi
  _fm_lp_activate "$which" "$id" "$source" "$diag"
}

_fm_lp_need() {
  [ "${_FM_LP_READY:-0}" = 1 ]
}

fm_load_profile_stages() {
  _fm_lp_need || return 1
  local i
  for i in "${!_FM_LP_STAGE[@]}"; do
    printf '%s\n' "${_FM_LP_STAGE[$i]}"
  done
}

fm_load_profile_policy() {  # <stage-id>
  _fm_lp_need || return 1
  local i stage=${1-}
  for i in "${!_FM_LP_STAGE[@]}"; do
    if [ "${_FM_LP_STAGE[$i]}" = "$stage" ]; then
      printf '%s\n' "${_FM_LP_POLICY[$i]}"
      return 0
    fi
  done
  _fm_lp_die "unknown stage $stage" || return 1
}

fm_load_profile_memory_slots() {
  _fm_lp_need || return 1
  local policy
  policy=$(fm_load_profile_policy context) || return 1
  case "$policy" in
    *' emit=slots '*) ;;
    *) return 0 ;;
  esac
  [ -n "$_FM_LP_SLOTS" ] || return 1
  printf '%s\n' "$_FM_LP_SLOTS"
}

fm_load_profile_bound_id() {
  _fm_lp_need || return 1
  printf '%s\n' "$_FM_LP_ID"
}

fm_load_profile_source() {
  _fm_lp_need || return 1
  printf '%s\n' "$_FM_LP_SOURCE"
}

fm_load_profile_diagnostic() {
  _fm_lp_need || return 1
  if [ -n "$_FM_LP_DIAG" ]; then
    printf '%s\n' "$_FM_LP_DIAG"
  fi
}

fm_load_profile_slim_max_bytes() {
  printf '%s\n' "$_FM_LP_SLIM_MAX_BYTES"
}
