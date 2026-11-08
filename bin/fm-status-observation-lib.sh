#!/usr/bin/env bash
# Cursor-free point-in-time observations for read-only crew/fleet consumers.
# Source after fm-classify-lib.sh. fm_status_observation_json <log> <kind>
# emits {current,latest,previous,wait,raw,pr,open,endpoint,identity}.
# A private disposable cache under TMPDIR replays only complete appended records
# using the authoritative parser/fold. No home cursor, delivery receipt, status
# log or task state is written. Cache damage/version/kind/config/identity changes
# rebuild from raw history. I/O failures return nonzero for the caller's legacy
# fallback. Concurrent append is pinned to one endpoint; replacement is refused.
# Unterminated records are observed, but never cached, so completing a partial
# append cannot turn its suffix into a separate event. Cache races can only
# cause extra replay. Same-inode in-place edits remain unsupported, as in the
# existing append-only incremental fold.
# Validate a bounded prefix and the old endpoint before trusting append-only
# history. This detects ordinary same-inode rewrites without hashing the whole
# lifetime prefix. Arbitrary in-place edits outside these windows are unsupported.
_fm_status_observation_witness() {  # <file> <endpoint>
  perl -MFcntl=:DEFAULT -MDigest::SHA=sha256_hex -e '
    my ($path, $end) = @ARGV;
    sysopen(my $f, $path, O_RDONLY | O_NOFOLLOW) or exit 1;
    my $n = $end < 512 ? $end : 512;
    my $bytes = "";
    for my $start (0, $end - $n) {
      sysseek($f, $start, 0) == $start or exit 1;
      my $got = sysread($f, my $chunk, $n);
      defined($got) && $got == $n or exit 1;
      $bytes .= $chunk;
    }
    print sha256_hex($bytes);
  ' "$1" "$2"
}

fm_status_observation_json() (
  local f=$1 kind=$2 dir key cache token parser_digest data='' offset=0 size ident chunk line complete
  local latest='' previous='' wait='' raw='' pr='' open='' current='' event='' verb resolve held legacy key_line digest canonical
  local cached_ident cached_token cached_offset scratch actual_ident actual_size witness cached_witness
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 1
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  legacy="^[[:space:]]*(${FM_CAPTAIN_RE:-$FM_CLASSIFY_CAPTAIN_RE_DEFAULT})"
  # Parser source hashes invalidate observations when event parsing changes
  # independently of the decision-fold version.
  parser_digest=$(perl -MDigest::SHA -e 'my $d=Digest::SHA->new(256); for (@ARGV) { open my $f,"<",$_ or exit 1; binmode $f; $d->addfile($f); } print $d->hexdigest' \
    "$_FM_CLASSIFY_LIB_DIR/fm-classify-lib.sh" "$_FM_CLASSIFY_LIB_DIR/fm-status-observation-lib.sh") || return 1
  token=$(printf '%s\n' "$parser_digest" "$FM_OPEN_DECISIONS_FOLD_VERSION" "$kind" "$resolve" "$held" \
    "${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}" "$legacy" \
    "${FM_CLASSIFY_RESERVED_KEY_PREFIXES:-$FM_CLASSIFY_RESERVED_KEY_PREFIXES_DEFAULT}" \
    | perl -MDigest::SHA=sha256_hex -0777 -ne 'print sha256_hex($_)') || return 1
  key=$(printf '%s' "$f" | perl -MDigest::SHA=sha256_hex -0777 -ne 'print sha256_hex($_)') || return 1
  dir="${TMPDIR:-/tmp}/fm-status-observations-$UID"
  if [ ! -e "$dir" ]; then (umask 077; mkdir "$dir") 2>/dev/null || :; fi
  [ -d "$dir" ] && [ ! -L "$dir" ] && [ -O "$dir" ] || return 1
  chmod 700 "$dir" || return 1
  cache="$dir/$key.json"
  _fm_status_read_ident_size "$f" || return 1
  ident=$_FM_STAT_IDENTITY size=$_FM_STAT_SIZE
  case "$size" in ''|*[!0-9]*) return 1 ;; esac
  if [ -f "$cache" ] && [ ! -L "$cache" ]; then
    canonical=$(jq -ecS 'del(.checksum)' "$cache" 2>/dev/null) || canonical=''
    digest=$(printf '%s' "$canonical" | perl -MDigest::SHA=sha256_hex -0777 -ne 'print sha256_hex($_)') || return 1
    if [ -n "$canonical" ] && [ "$(jq -r '.checksum // empty' "$cache" 2>/dev/null)" = "$digest" ]; then
      data=$(jq -er 'select(.schema == 1 and (.endpoint|type) == "number" and .endpoint >= 0
      and (.endpoint|floor) == .endpoint
      and ([.token,.identity,.witness,.latest,.previous,.wait,.raw,.pr,.open,.event]|all(type == "string")))
      | .token,.identity,.endpoint,.witness,.latest,.previous,.wait,.raw,.pr,.event,.open' "$cache" 2>/dev/null) || data=''
    fi
  fi
  if [ -n "$data" ]; then
    {
      IFS= read -r cached_token; IFS= read -r cached_ident; IFS= read -r cached_offset; IFS= read -r cached_witness
      if [ "$cached_token" = "$token" ] && [ "$cached_ident" = "$ident" ] && [ "$cached_offset" -le "$size" ] \
        && [ "$(_fm_status_observation_witness "$f" "$cached_offset")" = "$cached_witness" ]; then
        offset=$cached_offset
        IFS= read -r latest; IFS= read -r previous; IFS= read -r wait
        IFS= read -r raw; IFS= read -r pr; IFS= read -r event
        open=$(cat)
      fi
    } <<< "$data"
  fi
  chunk=$(umask 077; mktemp "$dir/read.XXXXXX") || return 1
  scratch=$(umask 077; mktemp "$dir/cache.XXXXXX") || { rm -f "$chunk"; return 1; }
  trap 'rm -f "$chunk" "$scratch"' EXIT
  _fm_status_read_span "$f" "$offset" "$((size - offset))" > "$chunk" || return 1
  [ -z "${FM_STATUS_OBSERVATION_READ_PROBE:-}" ] || printf '%s\t%s\n' "$f" "$((size - offset))" >> "$FM_STATUS_OBSERVATION_READ_PROBE"
  complete=1
  while IFS= read -r line || { [ -n "$line" ] && { complete=0; true; }; }; do
    case "$line" in *[![:space:]]*) raw=$line ;; *) continue ;; esac
    open=$(_fm_decision_fold_line "$open" "$line" "$resolve" "$held" "$kind")
    if _fm_status_line_is_event "$line" "$legacy"; then
      previous=$event event=$line latest=$line
      status_line_verb "$line" verb
      if status_is_paused_or_captain_held "$line"; then
        wait=$line
      elif [ "$verb" = "$resolve" ] && [ -n "$wait" ]; then
        wait=$(printf '%s\n%s\n' "$wait" "$line" | _fm_status_declared_wait_scan "$resolve" "$legacy") || wait=''
      else
        wait=''
      fi
    elif [ -z "$event" ]; then latest=$raw; fi
  done < "$chunk"
  if [ -z "$pr" ]; then
    pr=$(grep -Eo 'https?://[^[:space:])"]+/pull/[0-9]+' "$chunk" | head -1) || pr=''
  fi
  current=''
  while IFS=$'\t' read -r key_line verb line; do
    [ -z "$verb" ] || current="$verb [key=$key_line]: $line"
  done <<< "$open"
  [ -n "$current" ] || current=${wait:-$latest}
  _fm_status_read_ident_size "$f" || return 1
  actual_ident=$_FM_STAT_IDENTITY actual_size=$_FM_STAT_SIZE
  [ "$actual_ident" = "$ident" ] && [ "$actual_size" -ge "$size" ] || return 1
  witness=$(_fm_status_observation_witness "$f" "$size") || return 1
  # File-based encoding avoids argv limits for large open sets and long notes.
  printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s' \
    "$latest" "$previous" "$wait" "$raw" "$pr" "$event" "$current" "$ident" "$open" > "$scratch"
  jq -Rn --arg token "$token" --arg witness "$witness" --argjson endpoint "$size" '
    [inputs] as $v | {schema:1,token:$token,witness:$witness,endpoint:$endpoint,
    latest:$v[0],previous:$v[1],wait:$v[2],raw:$v[3],pr:$v[4],event:$v[5],current:$v[6],identity:$v[7],open:($v[8:]|join("\n"))}' \
    < "$scratch" > "$chunk" || return 1
  canonical=$(jq -cS . "$chunk") || return 1
  digest=$(printf '%s' "$canonical" | perl -MDigest::SHA=sha256_hex -0777 -ne 'print sha256_hex($_)') || return 1
  jq --arg digest "$digest" '. + {checksum:$digest}' "$chunk" > "$scratch" || return 1
  cat "$scratch" || return 1
  if [ "$complete" -eq 1 ]; then mv -f "$scratch" "$cache" || :; fi
)
