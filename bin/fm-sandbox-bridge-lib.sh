#!/usr/bin/env bash
# shellcheck shell=bash
# Private Docker Sandbox bridge lifecycle for one task.
#
# The bridge is a verified directory under <state>/sandbox-bridge/<task-id>.
# Its binding records canonical host identities.  Runtime writers receive only
# the bridge.  The append cursor stays in host-private canonical state, outside
# the mounted bridge, so the sandbox cannot advance or reset it.

fm_sandbox_bridge_error() {
  printf 'error: %s\n' "$*" >&2
}

fm_sandbox_bridge_task_id_valid() {  # <task-id>
  case "$1" in
    ''|.*|*..*|*/*|*\\*|*[![:alnum:]._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

fm_sandbox_bridge_no_newline() {  # <value>
  case "$1" in
    *$'\n'*|*$'\r'*) return 1 ;;
    *) return 0 ;;
  esac
}

fm_sandbox_bridge_real_dir() {  # <path>
  [ -n "$1" ] && [ -d "$1" ] && [ ! -L "$1" ] || return 1
  CDPATH='' cd -- "$1" 2>/dev/null && pwd -P
}

fm_sandbox_bridge_file_regular() {  # <path>
  [ -f "$1" ] && [ ! -L "$1" ]
}

# Require an owned regular file with no group or other write permission.
fm_sandbox_bridge_safe_regular() {  # <path>
  perl -e 'my @s = lstat($ARGV[0]) or exit 1; exit 1 unless -f _ && $s[4] == $< && !($s[2] & 0022);' "$1"
}

# Cursor state is host-private, not merely safe for bridge writers.
fm_sandbox_bridge_private_regular() {  # <path>
  perl -e 'my @s = lstat($ARGV[0]) or exit 1; exit 1 unless -f _ && $s[4] == $< && !($s[2] & 0077);' "$1"
}

fm_sandbox_bridge_lstat_identity() {  # <path>
  perl -e 'my @s = lstat($ARGV[0]) or exit 1; print "$s[0]:$s[1]";' "$1"
}

# shellcheck disable=SC2034
FM_SANDBOX_BRIDGE_ACQUIRED_PATH=
# shellcheck disable=SC2034
FM_SANDBOX_BRIDGE_ACQUIRED_ID=
# shellcheck disable=SC2034
FM_SANDBOX_BRIDGE_ACQUIRED_CURSOR_ID=

fm_sandbox_bridge_expected_path() {  # <state> <task-id>
  local state=$1 task_id=$2 state_real
  fm_sandbox_bridge_task_id_valid "$task_id" || return 1
  state_real=$(fm_sandbox_bridge_real_dir "$state") || return 1
  printf '%s/sandbox-bridge/%s' "$state_real" "$task_id"
}

fm_sandbox_bridge_cursor_path() {  # <state> <task-id>
  local state=$1 task_id=$2 state_real
  fm_sandbox_bridge_task_id_valid "$task_id" || return 1
  state_real=$(fm_sandbox_bridge_real_dir "$state") || return 1
  printf '%s/sandbox-bridge-cursor/%s' "$state_real" "$task_id"
}

fm_sandbox_bridge_binding_value() {  # <binding> <key>
  local binding=$1 key=$2 count
  fm_sandbox_bridge_safe_regular "$binding" || return 1
  count=$(grep -c "^${key}=" "$binding" 2>/dev/null || true)
  [ "$count" = 1 ] || return 1
  sed -n "s/^${key}=//p" "$binding"
}

fm_sandbox_bridge_read_cursor() {  # <host-private cursor>
  perl -MFcntl=':DEFAULT,O_NOFOLLOW' -e '
    sysopen(my $fh, $ARGV[0], O_RDONLY | O_NOFOLLOW) or exit 1;
    my @s = stat($fh); exit 1 unless -f $fh && $s[4] == $< && !($s[2] & 0077);
    my $value = <$fh>; exit 1 unless defined $value && $value =~ /\A([0-9]+)\n\z/ && eof($fh);
    print $1;
  ' "$1"
}

# fm_sandbox_bridge_validate_bridge: verify one bridge without requiring its cursor.
fm_sandbox_bridge_validate_bridge() {  # <bridge> <state> <task-id> <worktree>
  [ "$#" -eq 4 ] || {
    [ "$#" -eq 5 ] && [ "$5" = allow-missing-worktree ] || {
      fm_sandbox_bridge_error 'usage: fm_sandbox_bridge_validate_bridge <bridge> <state> <task-id> <worktree>'
      return 2
    }
  }
  local bridge=$1 state=$2 task_id=$3 worktree=$4 expected cursor state_real worktree_real bridge_root cursor_root bridge_real allow_missing_worktree=0 worktree_parent worktree_leaf worktree_parent_real
  local bound_task bound_state bound_worktree bound_bridge bound_cursor
  [ "$#" -eq 5 ] && allow_missing_worktree=1
  expected=$(fm_sandbox_bridge_expected_path "$state" "$task_id") || {
    fm_sandbox_bridge_error 'sandbox bridge has an invalid state path or task identity'
    return 1
  }
  cursor=$(fm_sandbox_bridge_cursor_path "$state" "$task_id") || return 1
  state_real=$(fm_sandbox_bridge_real_dir "$state") || {
    fm_sandbox_bridge_error "sandbox bridge state is not a real directory: $state"
    return 1
  }
  if worktree_real=$(fm_sandbox_bridge_real_dir "$worktree"); then
    :
  elif [ "$allow_missing_worktree" = 1 ]; then
    case "$worktree" in
      /*)
        worktree_parent=${worktree%/*}
        worktree_leaf=${worktree##*/}
        [ -n "$worktree_parent" ] || worktree_parent=/
        [ -n "$worktree_leaf" ] || {
          fm_sandbox_bridge_error "sandbox bridge worktree is not a real directory: $worktree"
          return 1
        }
        worktree_parent_real=$(CDPATH='' cd -- "$worktree_parent" 2>/dev/null && pwd -P) || {
          fm_sandbox_bridge_error "sandbox bridge worktree is not a real directory: $worktree"
          return 1
        }
        worktree_real=$worktree_parent_real/$worktree_leaf
        ;;
      *)
        fm_sandbox_bridge_error "sandbox bridge worktree is not a real directory: $worktree"
        return 1
        ;;
    esac
  else
    fm_sandbox_bridge_error "sandbox bridge worktree is not a real directory: $worktree"
    return 1
  fi
  [ "$bridge" = "$expected" ] || {
    fm_sandbox_bridge_error "sandbox bridge path does not match its task identity: $bridge"
    return 1
  }
  bridge_real=$(fm_sandbox_bridge_real_dir "$bridge") || {
    fm_sandbox_bridge_error "sandbox bridge is not a real directory: $bridge"
    return 1
  }
  [ "$bridge_real" = "$expected" ] || {
    fm_sandbox_bridge_error "sandbox bridge path is not canonical: $bridge"
    return 1
  }
  bridge_root=$(fm_sandbox_bridge_real_dir "$state_real/sandbox-bridge") || return 1
  cursor_root=$(fm_sandbox_bridge_real_dir "$state_real/sandbox-bridge-cursor") || return 1
  if ! {
    [ "$bridge_root" = "$state_real/sandbox-bridge" ] &&
      [ "$cursor_root" = "$state_real/sandbox-bridge-cursor" ] &&
      perl -e 'my @s = lstat($ARGV[0]) or exit 1; exit 1 unless -d _ && $s[4] == $< && !($s[2] & 0022);' "$bridge_root" &&
      perl -e 'my @s = lstat($ARGV[0]) or exit 1; exit 1 unless -d _ && $s[4] == $< && !($s[2] & 0077);' "$cursor_root"
  }; then
    fm_sandbox_bridge_error 'sandbox bridge root or host-private cursor root is unsafe'
    return 1
  fi
  if ! {
      fm_sandbox_bridge_safe_regular "$bridge/binding" &&
      fm_sandbox_bridge_safe_regular "$bridge/status" &&
      fm_sandbox_bridge_safe_regular "$bridge/runtime-brief.md" &&
      fm_sandbox_bridge_safe_regular "$bridge/fm-operational-input.sh"
  }; then
    fm_sandbox_bridge_error "sandbox bridge inputs are missing or unsafe: $bridge"
    return 1
  fi
  bound_task=$(fm_sandbox_bridge_binding_value "$bridge/binding" task_id) || return 1
  bound_state=$(fm_sandbox_bridge_binding_value "$bridge/binding" state) || return 1
  bound_worktree=$(fm_sandbox_bridge_binding_value "$bridge/binding" worktree) || return 1
  bound_bridge=$(fm_sandbox_bridge_binding_value "$bridge/binding" bridge) || return 1
  bound_cursor=$(fm_sandbox_bridge_binding_value "$bridge/binding" cursor) || return 1
  if ! {
    [ "$bound_task" = "$task_id" ] &&
      [ "$bound_state" = "$state_real" ] &&
      [ "$bound_worktree" = "$worktree_real" ] &&
      [ "$bound_bridge" = "$expected" ] &&
      [ "$bound_cursor" = "$cursor" ]
  }; then
    fm_sandbox_bridge_error "sandbox bridge binding does not match task $task_id's canonical host identities"
    return 1
  fi
  # shellcheck disable=SC2034 # Public source-library out-parameter consumed by callers after sourcing.
  FM_SANDBOX_BRIDGE_PATH=$expected
  FM_SANDBOX_BRIDGE_CURSOR=$cursor
  return 0
}

# fm_sandbox_bridge_validate: verify one bridge and its host-private cursor.
fm_sandbox_bridge_validate() {  # <bridge> <state> <task-id> <worktree>
  [ "$#" -eq 4 ] || { fm_sandbox_bridge_error 'usage: fm_sandbox_bridge_validate <bridge> <state> <task-id> <worktree>'; return 2; }
  local cursor
  fm_sandbox_bridge_validate_bridge "$@" || return 1
  cursor=$FM_SANDBOX_BRIDGE_CURSOR
  fm_sandbox_bridge_private_regular "$cursor" || {
    fm_sandbox_bridge_error "sandbox bridge host-private cursor is missing or unsafe: $cursor"
    return 1
  }
  fm_sandbox_bridge_read_cursor "$cursor" >/dev/null || {
    fm_sandbox_bridge_error "sandbox bridge cursor is malformed or unsafe: $cursor"
    return 1
  }
  return 0
}

# fm_sandbox_bridge_create: create a bridge and a separate host-private cursor.
fm_sandbox_bridge_create() {  # <state> <task-id> <worktree> <canonical-brief> <encoder>
  local state=$1 task_id=$2 worktree=$3 brief=$4 encoder=$5 expected cursor state_real worktree_real old_umask runtime_brief_tmp
  [ "$#" -eq 5 ] || { fm_sandbox_bridge_error 'usage: fm_sandbox_bridge_create <state> <task-id> <worktree> <canonical-brief> <encoder>'; return 2; }
  FM_SANDBOX_BRIDGE_ACQUIRED_PATH=
  FM_SANDBOX_BRIDGE_ACQUIRED_ID=
  FM_SANDBOX_BRIDGE_ACQUIRED_CURSOR_ID=
  expected=$(fm_sandbox_bridge_expected_path "$state" "$task_id") || return 1
  cursor=$(fm_sandbox_bridge_cursor_path "$state" "$task_id") || return 1
  state_real=$(fm_sandbox_bridge_real_dir "$state") || return 1
  worktree_real=$(fm_sandbox_bridge_real_dir "$worktree") || return 1
  case "$brief" in -*) brief=./$brief ;; esac
  case "$encoder" in -*) encoder=./$encoder ;; esac
  if ! {
    fm_sandbox_bridge_safe_regular "$brief" &&
      fm_sandbox_bridge_safe_regular "$encoder"
  }; then
    fm_sandbox_bridge_error 'sandbox bridge requires safe regular canonical brief and operational-input encoder files'
    return 1
  fi
  if ! {
    fm_sandbox_bridge_no_newline "$state_real" &&
      fm_sandbox_bridge_no_newline "$worktree_real" &&
      fm_sandbox_bridge_no_newline "$expected" &&
      fm_sandbox_bridge_no_newline "$cursor"
  }; then
    fm_sandbox_bridge_error 'sandbox bridge identities must not contain newlines'
    return 1
  fi
  if ! {
    [ ! -e "$expected" ] &&
      [ ! -L "$expected" ] &&
      [ ! -e "$cursor" ] &&
      [ ! -L "$cursor" ]
  }; then
    fm_sandbox_bridge_error "sandbox bridge identity collision for $task_id"
    return 1
  fi
  if ! {
    [ ! -L "$state_real/sandbox-bridge" ] &&
      [ ! -L "$state_real/sandbox-bridge-cursor" ]
  }; then
    fm_sandbox_bridge_error 'sandbox bridge root or cursor root is symlinked'
    return 1
  fi
  old_umask=$(umask)
  umask 077
  if ! mkdir -p "$state_real/sandbox-bridge" "$state_real/sandbox-bridge-cursor" || ! mkdir "$expected"; then
    umask "$old_umask"
    fm_sandbox_bridge_error "could not create private sandbox bridge for $task_id"
    return 1
  fi
  FM_SANDBOX_BRIDGE_ACQUIRED_PATH=$expected
  FM_SANDBOX_BRIDGE_ACQUIRED_ID=$(fm_sandbox_bridge_lstat_identity "$expected") || {
    umask "$old_umask"
    fm_sandbox_bridge_error "could not identify private sandbox bridge for $task_id"
    return 1
  }
  if ! printf '0\n' > "$cursor"; then
    umask "$old_umask"
    fm_sandbox_bridge_error "could not initialize private sandbox bridge cursor for $task_id"
    return 1
  fi
  FM_SANDBOX_BRIDGE_ACQUIRED_CURSOR_ID=$(fm_sandbox_bridge_lstat_identity "$cursor") || {
    umask "$old_umask"
    fm_sandbox_bridge_error "could not identify private sandbox bridge cursor for $task_id"
    return 1
  }
  {
    printf 'task_id=%s\n' "$task_id"
    printf 'state=%s\n' "$state_real"
    printf 'worktree=%s\n' "$worktree_real"
    printf 'bridge=%s\n' "$expected"
    printf 'cursor=%s\n' "$cursor"
  } > "$expected/binding"
  : > "$expected/status"
  runtime_brief_tmp=$(mktemp "$expected/.runtime-brief.md.tmp.XXXXXX") || {
    umask "$old_umask"
    fm_sandbox_bridge_remove_acquired \
      "$expected" "$state_real" "$task_id" "$worktree_real" \
      "$FM_SANDBOX_BRIDGE_ACQUIRED_ID" "$FM_SANDBOX_BRIDGE_ACQUIRED_CURSOR_ID" || true
    fm_sandbox_bridge_error "could not prepare sandbox bridge runtime inputs: $expected"
    return 1
  }
  if ! {
    cp "$brief" "$runtime_brief_tmp" &&
      chmod 600 "$runtime_brief_tmp" &&
      mv -f "$runtime_brief_tmp" "$expected/runtime-brief.md" &&
      cp "$encoder" "$expected/fm-operational-input.sh" &&
      chmod 700 "$expected/fm-operational-input.sh"
  }; then
    rm -f "$runtime_brief_tmp"
    umask "$old_umask"
    fm_sandbox_bridge_remove_acquired \
      "$expected" "$state_real" "$task_id" "$worktree_real" \
      "$FM_SANDBOX_BRIDGE_ACQUIRED_ID" "$FM_SANDBOX_BRIDGE_ACQUIRED_CURSOR_ID" || true
    fm_sandbox_bridge_error "could not prepare sandbox bridge runtime inputs: $expected"
    return 1
  fi
  chmod 600 "$expected/binding" "$expected/status" "$expected/runtime-brief.md" "$cursor"
  umask "$old_umask"
  fm_sandbox_bridge_validate "$expected" "$state_real" "$task_id" "$worktree_real" || {
    fm_sandbox_bridge_remove_acquired \
      "$expected" "$state_real" "$task_id" "$worktree_real" \
      "$FM_SANDBOX_BRIDGE_ACQUIRED_ID" "$FM_SANDBOX_BRIDGE_ACQUIRED_CURSOR_ID" || true
    return 1
  }
}

fm_sandbox_bridge_remove_acquired() {  # <bridge> <state> <task-id> <worktree> <bridge-id> [cursor-id]
  [ "$#" -ge 5 ] && [ "$#" -le 6 ] || {
    fm_sandbox_bridge_error 'usage: fm_sandbox_bridge_remove_acquired <bridge> <state> <task-id> <worktree> <bridge-id> [cursor-id]'
    return 2
  }
  local bridge=$1 state=$2 task_id=$3 bridge_id=$5 cursor_id=${6:-} expected cursor current
  expected=$(fm_sandbox_bridge_expected_path "$state" "$task_id") || return 1
  cursor=$(fm_sandbox_bridge_cursor_path "$state" "$task_id") || return 1
  [ "$bridge" = "$expected" ] || return 1
  if [ ! -e "$bridge" ] && [ ! -L "$bridge" ] && [ ! -e "$cursor" ] && [ ! -L "$cursor" ]; then
    return 0
  fi
  if [ -e "$bridge" ] || [ -L "$bridge" ]; then
    [ -d "$bridge" ] && [ ! -L "$bridge" ] || return 1
    current=$(fm_sandbox_bridge_lstat_identity "$bridge") || return 1
    [ "$current" = "$bridge_id" ] || return 1
  fi
  if [ -e "$cursor" ] || [ -L "$cursor" ]; then
    [ -f "$cursor" ] && [ ! -L "$cursor" ] || return 1
    [ -n "$cursor_id" ] || return 1
    current=$(fm_sandbox_bridge_lstat_identity "$cursor") || return 1
    [ "$current" = "$cursor_id" ] || return 1
  fi
  if [ -e "$bridge" ] || [ -L "$bridge" ]; then
    rm -rf "$bridge" || return 1
  fi
  if [ -e "$cursor" ] || [ -L "$cursor" ]; then
    rm -f "$cursor" || return 1
  fi
}

fm_sandbox_bridge_copy_delta() {  # <bridge-status> <cursor> <host-private tmp>
  perl -MFcntl=':DEFAULT,O_NOFOLLOW' -e '
    my ($path, $cursor, $out) = @ARGV;
    sysopen(my $in, $path, O_RDONLY | O_NOFOLLOW) or exit 1;
    my @s = stat($in); exit 1 unless -f $in && $s[4] == $< && !($s[2] & 0022);
    exit 1 unless $cursor =~ /\A[0-9]+\z/ && $s[7] >= $cursor;
    my $size = $s[7]; my $left = $size - $cursor;
    exit 1 if $left > 65536;
    sysopen(my $fh, $out, O_WRONLY | O_TRUNC | O_NOFOLLOW) or exit 1;
    my @o = stat($fh); exit 1 unless -f $fh && $o[4] == $< && !($o[2] & 0077);
    seek($in, $cursor, 0) or exit 1;
    while ($left) { my $want = $left > 8192 ? 8192 : $left; my $n = sysread($in, my $buf, $want); exit 1 unless defined $n && $n; print {$fh} $buf or exit 1; $left -= $n; }
    print $size;
  ' "$1" "$2" "$3"
}

fm_sandbox_bridge_delta_state() {  # <host-private delta> <canonical-status> <cursor>
  perl -MFcntl=':DEFAULT,O_NOFOLLOW' -e '
    my ($delta, $status, $cursor) = @ARGV;
    exit 1 unless $cursor =~ /\A[0-9]+\z/;
    sysopen(my $in, $delta, O_RDONLY | O_NOFOLLOW) or exit 1;
    my @d = stat($in); exit 1 unless -f $in && $d[4] == $< && !($d[2] & 0077);
    my $delta_size = $d[7]; exit 1 if $delta_size > 65536;
    my $status_size = 0;
    my $out;
    if (-e $status || -l $status) {
      sysopen($out, $status, O_RDONLY | O_NOFOLLOW) or exit 1;
      my @s = stat($out); exit 1 unless -f $out && $s[4] == $< && !($s[2] & 0022);
      $status_size = $s[7];
    }
    exit 1 if $status_size < $cursor;
    my $overlap = $status_size - $cursor;
    $overlap = $delta_size if $overlap > $delta_size;
    if ($overlap) {
      seek($in, 0, 0) or exit 1;
      seek($out, $cursor, 0) or exit 1;
      my $left = $overlap;
      while ($left) {
        my $want = $left > 8192 ? 8192 : $left;
        my $n = sysread($in, my $delta_buf, $want);
        my $m = sysread($out, my $status_buf, $want);
        exit 1 unless defined $n && $n == $want && defined $m && $m == $want && $delta_buf eq $status_buf;
        $left -= $want;
      }
    }
    if ($overlap == $delta_size) {
      print "committed";
    } else {
      print $overlap;
    }
  ' "$1" "$2" "$3"
}

fm_sandbox_bridge_append_delta() {  # <host-private delta> <canonical-status> <offset>
  perl -MFcntl=':DEFAULT,O_NOFOLLOW' -e '
    my ($delta, $status, $offset) = @ARGV;
    exit 1 unless $offset =~ /\A[0-9]+\z/;
    sysopen(my $in, $delta, O_RDONLY | O_NOFOLLOW) or exit 1;
    my @d = stat($in); exit 1 unless -f $in && $d[4] == $< && !($d[2] & 0077);
    exit 1 if $d[7] > 65536 || $offset > $d[7];
    sysopen(my $out, $status, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0600) or exit 1;
    my @s = stat($out); exit 1 unless -f $out && $s[4] == $< && !($s[2] & 0022);
    seek($in, $offset, 0) or exit 1;
    my $left = $d[7] - $offset;
    while (1) {
      last unless $left;
      my $want = $left > 8192 ? 8192 : $left;
      my $n = sysread($in, my $buf, $want);
      exit 1 unless defined $n;
      exit 1 unless $n == $want;
      print {$out} $buf or exit 1;
      $left -= $n;
    }
  ' "$1" "$2" "$3"
}

fm_sandbox_bridge_write_cursor() {  # <host-private cursor> <size>
  local cursor=$1 size=$2 tmp
  case "$size" in ''|*[!0-9]*) return 1 ;; esac
  fm_sandbox_bridge_private_regular "$cursor" || return 1
  tmp=$(mktemp "${cursor}.XXXXXX") || return 1
  if ! {
    chmod 600 "$tmp" &&
      printf '%s\n' "$size" > "$tmp" &&
      mv -f "$tmp" "$cursor"
  }; then
    rm -f "$tmp"
    return 1
  fi
}

fm_sandbox_bridge_touch_turnend() {  # <canonical turn-ended>
  perl -MFcntl=':DEFAULT,O_NOFOLLOW' -e '
    sysopen(my $fh, $ARGV[0], O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0600) or exit 1;
    my @s = stat($fh); exit 1 unless -f $fh && $s[4] == $< && !($s[2] & 0022);
  ' "$1"
}

# fm_sandbox_bridge_sync: append a bounded unseen delta and consume turn-ended once.
fm_sandbox_bridge_sync() {  # <bridge> <state> <task-id> <worktree>
  local bridge=$1 state=$2 task_id=$3 worktree=$4 cursor size delta_state tmp state_real canonical_status canonical_turnend
  [ "$#" -eq 4 ] || { fm_sandbox_bridge_error 'usage: fm_sandbox_bridge_sync <bridge> <state> <task-id> <worktree>'; return 2; }
  fm_sandbox_bridge_validate "$bridge" "$state" "$task_id" "$worktree" || return 1
  cursor=$(fm_sandbox_bridge_read_cursor "$FM_SANDBOX_BRIDGE_CURSOR") || {
    fm_sandbox_bridge_error 'sandbox bridge cursor is malformed'
    return 1
  }
  state_real=$(fm_sandbox_bridge_real_dir "$state") || return 1
  canonical_status=$state_real/$task_id.status
  canonical_turnend=$state_real/$task_id.turn-ended
  tmp=$(mktemp "$state_real/.sandbox-bridge-status.${task_id}.XXXXXX") || return 1
  size=$(fm_sandbox_bridge_copy_delta "$bridge/status" "$cursor" "$tmp") || {
    rm -f "$tmp"
    fm_sandbox_bridge_error 'sandbox bridge status is unsafe, truncated, or exceeds the 64 KiB append bound'
    return 1
  }
  if [ "$size" -gt "$cursor" ]; then
    delta_state=$(fm_sandbox_bridge_delta_state "$tmp" "$canonical_status" "$cursor") || {
      rm -f "$tmp"
      fm_sandbox_bridge_error "could not reconcile bridge status with canonical state for $task_id"
      return 1
    }
    case "$delta_state" in
      committed) ;;
      ''|*[!0-9]*)
        rm -f "$tmp"
        fm_sandbox_bridge_error "could not reconcile bridge status with canonical state for $task_id"
        return 1
        ;;
      *)
        fm_sandbox_bridge_append_delta "$tmp" "$canonical_status" "$delta_state" || {
          rm -f "$tmp"
          fm_sandbox_bridge_error "could not append bridge status to canonical state for $task_id"
          return 1
        }
        ;;
    esac
    fm_sandbox_bridge_write_cursor "$FM_SANDBOX_BRIDGE_CURSOR" "$size" || {
      rm -f "$tmp"
      fm_sandbox_bridge_error "could not transactionally advance sandbox bridge cursor for $task_id"
      return 1
    }
  fi
  rm -f "$tmp"
  if [ -e "$bridge/turn-ended" ] || [ -L "$bridge/turn-ended" ]; then
    fm_sandbox_bridge_safe_regular "$bridge/turn-ended" || {
      fm_sandbox_bridge_error "sandbox bridge turn-end marker is unsafe: $bridge/turn-ended"
      return 1
    }
    fm_sandbox_bridge_touch_turnend "$canonical_turnend" || {
      fm_sandbox_bridge_error "canonical turn-end marker is unsafe: $canonical_turnend"
      return 1
    }
    rm -f "$bridge/turn-ended" || {
      fm_sandbox_bridge_error "could not consume sandbox bridge turn-end marker: $bridge/turn-ended"
      return 1
    }
  fi
}

# fm_sandbox_bridge_remove: remove only a currently verified bridge and cursor.
fm_sandbox_bridge_remove() {  # <bridge> <state> <task-id> <worktree>
  [ "$#" -eq 4 ] || { fm_sandbox_bridge_error 'usage: fm_sandbox_bridge_remove <bridge> <state> <task-id> <worktree>'; return 2; }
  local bridge=$1 state=$2 task_id=$3 worktree=$4 expected cursor worktree_is_dir=0
  expected=$(fm_sandbox_bridge_expected_path "$state" "$task_id") || return 1
  cursor=$(fm_sandbox_bridge_cursor_path "$state" "$task_id") || return 1
  [ "$bridge" = "$expected" ] || return 1
  if [ -d "$worktree" ] && [ ! -L "$worktree" ]; then
    worktree_is_dir=1
  fi
  if [ ! -e "$bridge" ] && [ ! -L "$bridge" ] && [ ! -e "$cursor" ] && [ ! -L "$cursor" ]; then
    return 0
  fi
  if [ -e "$bridge" ] || [ -L "$bridge" ]; then
    if [ "$worktree_is_dir" = 1 ] && { [ -e "$cursor" ] || [ -L "$cursor" ]; }; then
      fm_sandbox_bridge_validate "$bridge" "$state" "$task_id" "$worktree" || return 1
    elif [ "$worktree_is_dir" = 1 ]; then
      fm_sandbox_bridge_validate_bridge "$bridge" "$state" "$task_id" "$worktree" || return 1
    else
      fm_sandbox_bridge_validate_bridge "$bridge" "$state" "$task_id" "$worktree" allow-missing-worktree || return 1
      if [ -e "$cursor" ] || [ -L "$cursor" ]; then
        fm_sandbox_bridge_private_regular "$cursor" || return 1
        fm_sandbox_bridge_read_cursor "$cursor" >/dev/null || return 1
      fi
    fi
    rm -rf "$bridge" || return 1
  fi
  if [ -e "$cursor" ] || [ -L "$cursor" ]; then
    fm_sandbox_bridge_private_regular "$cursor" || return 1
    fm_sandbox_bridge_read_cursor "$cursor" >/dev/null || return 1
    rm -f "$cursor" || return 1
  fi
}
