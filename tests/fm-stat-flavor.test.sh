#!/usr/bin/env bash
# tests/fm-stat-flavor.test.sh - portable file-timestamp handling (issue #1601).
#
# The hazard is a macOS host whose PATH puts GNU coreutils ahead of /usr/bin:
# `uname` still says Darwin, but `stat` speaks GNU, so a Darwin-name branch runs
# `stat -f %m <file>` - GNU *file-system* stat, which writes a multi-line dump to
# STDOUT and fails. A `stat -f ... || stat -c ...` chain is worse: it exits ZERO
# with the correct epoch appended to that dump. Either way the reader hands a
# non-numeric token to arithmetic, and a live watcher beacon, a held git lock, or
# an X reply-context record ages wrongly - or kills its own process.
#
# These cases run the real production readers against both stat command-line
# flavors, plus a native-stat control, so the behavior is asserted rather than
# assumed. Each flavor case runs in a fresh process because the flavor probe
# binds at source time.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-stat-flavor-tests)
REAL_STAT=$(command -v stat)
[ -n "$REAL_STAT" ] || fail "no stat on PATH; cannot build a flavor shim"

# Every file loaded into the fm-watch.sh, fm-supervise-daemon.sh, or fm-guard.sh
# process that reads file metadata. This is the graph whose readers decide
# watcher liveness, lock staleness, and artifact safety, so none of them may
# re-derive a stat flavor.
STAT_OWNERS="fm-watch.sh fm-crew-state.sh fm-wake-lib.sh fm-lock-lib.sh
fm-x-lib.sh fm-pr-lib.sh fm-pending-reply-lib.sh fm-supervise-daemon.sh
fm-supervision-lib.sh fm-guard.sh fm-busy-event.sh fm-classify-lib.sh"

# --- flavor shims -----------------------------------------------------------
#
# A `stat` that accepts exactly ONE flavor's command line, backed by the host's
# real stat for the underlying numbers. The GNU shim reproduces the trap
# faithfully: `-f` is file-system mode taking no format argument, so the format
# string becomes an unreadable operand and the dump lands on stdout.

make_stat_shim() {  # <case-dir> <gnu|bsd> -> echoes the shim bin dir
  local dir=$1 flavor=$2 bin="$1/stat-$2"
  mkdir -p "$bin"
  cat > "$bin/stat" <<SHIM
#!/usr/bin/env bash
set -u
FLAVOR=$flavor
REAL=\${FM_TEST_REAL_STAT:?FM_TEST_REAL_STAT unset}
SHIM
  cat >> "$bin/stat" <<'SHIM'
if "$REAL" -c %Y / >/dev/null 2>&1; then
  real_datum() {  # <mtime|size|mode|device|inode|nlink|ctime> <file>
    case "$1" in
      mtime)  "$REAL" -c %Y "$2" ;;
      size)   "$REAL" -c %s "$2" ;;
      mode)   "$REAL" -c %a "$2" ;;
      device) "$REAL" -c %d "$2" ;;
      inode)  "$REAL" -c %i "$2" ;;
      nlink)  "$REAL" -c %h "$2" ;;
      ctime)  "$REAL" -c %Z "$2" ;;
    esac
  }
else
  real_datum() {
    case "$1" in
      mtime)  "$REAL" -f %m "$2" ;;
      size)   "$REAL" -f %z "$2" ;;
      mode)   "$REAL" -f %Lp "$2" ;;
      device) "$REAL" -f %d "$2" ;;
      inode)  "$REAL" -f %i "$2" ;;
      nlink)  "$REAL" -f %l "$2" ;;
      ctime)  LC_ALL=C "$REAL" -f %c "$2" ;;
    esac
  }
fi

# Emit <datum> when this flavor owns <spec>, otherwise `?` - exactly what the
# real binaries print for a specifier they do not know.
owned() {  # <owning-flavor> <datum> <file>
  local want=$1 datum=$2 f=$3 v
  if [ "$FLAVOR" != "$want" ]; then printf '?'; return 0; fi
  v=$(real_datum "$datum" "$f") || return 1
  printf '%s' "$v"
}

# Expand one format string the way $FLAVOR would.
expand() {  # <fmt> <file>
  local f=$2 out='' rest=$1 piece
  while [ -n "$rest" ]; do
    if [ "${rest:0:1}" != '%' ]; then
      out="$out${rest:0:1}"; rest=${rest:1}; continue
    fi
    case "$rest" in
      %Fm*) rest=${rest#%Fm}; piece=$(owned bsd mtime "$f") || return 1
            [ "$piece" = '?' ] || piece="$piece.000000000" ;;
      %Lp*) rest=${rest#%Lp}; piece=$(owned bsd mode "$f") || return 1 ;;
      %m*)  rest=${rest#%m};  piece=$(owned bsd mtime "$f") || return 1 ;;
      %z*)  rest=${rest#%z};  piece=$(owned bsd size "$f") || return 1 ;;
      %l*)  rest=${rest#%l};  piece=$(owned bsd nlink "$f") || return 1 ;;
      %c*)  rest=${rest#%c};  piece=$(owned bsd ctime "$f") || return 1 ;;
      %Y*)  rest=${rest#%Y};  piece=$(owned gnu mtime "$f") || return 1 ;;
      %s*)  rest=${rest#%s};  piece=$(owned gnu size "$f") || return 1 ;;
      %a*)  rest=${rest#%a};  piece=$(owned gnu mode "$f") || return 1 ;;
      %h*)  rest=${rest#%h};  piece=$(owned gnu nlink "$f") || return 1 ;;
      %Z*)  rest=${rest#%Z};  piece=$(owned gnu ctime "$f") || return 1 ;;
      # Both flavors spell device and inode the same way.
      %d*)  rest=${rest#%d};  piece=$(real_datum device "$f") || return 1 ;;
      %i*)  rest=${rest#%i};  piece=$(real_datum inode "$f") || return 1 ;;
      %%*)  rest=${rest#%%};  piece='%' ;;
      *)    rest=${rest:1};   piece='?' ;;
    esac
    out="$out$piece"
  done
  printf '%s\n' "$out"
}

fmt=''
fsmode=0
operands=()
while [ "$#" -gt 0 ]; do
  case "$FLAVOR:$1" in
    gnu:-c)            fmt=${2:-}; shift 2 || exit 1 ;;
    gnu:--format=*)    fmt=${1#--format=}; shift ;;
    gnu:-f|gnu:--file-system) fsmode=1; shift ;;
    bsd:-f)            fmt=${2:-}; shift 2 || exit 1 ;;
    bsd:-L|bsd:-n|bsd:-q|bsd:-r|bsd:-s|bsd:-x) shift ;;
    *:--)              shift; while [ "$#" -gt 0 ]; do operands+=("$1"); shift; done ;;
    *:-*)
      if [ "$FLAVOR" = gnu ]; then
        printf "stat: unrecognized option '%s'\n" "$1" >&2
      else
        printf 'stat: illegal option -- %s\n' "${1#-}" >&2
        printf 'usage: stat [-FLnq] [-f format | -l | -r | -s | -x] [-t timefmt] [file ...]\n' >&2
      fi
      exit 1
      ;;
    *)                 operands+=("$1"); shift ;;
  esac
done

rc=0
for op in ${operands[@]+"${operands[@]}"}; do
  if [ "$fsmode" = 1 ]; then
    # GNU file-system mode: the dump goes to STDOUT even as a sibling operand
    # fails, which is precisely what poisons a `-f || -c` fallback chain.
    if [ -e "$op" ]; then
      printf '  File: "%s"\n    ID: 0 Namelen: 255     Type: apfs\nBlock size: 4096\nBlocks: Total: 1000       Free: 500       Available: 500\n' "$op"
    else
      printf "stat: cannot read file system information for '%s': No such file or directory\n" "$op" >&2
      rc=1
    fi
    continue
  fi
  if [ ! -e "$op" ]; then
    printf "stat: cannot stat '%s': No such file or directory\n" "$op" >&2
    rc=1
    continue
  fi
  expand "$fmt" "$op" || rc=1
done
exit "$rc"
SHIM
  chmod +x "$bin/stat"
  printf '%s\n' "$bin"
}

make_case() {  # <name> -> echoes a fresh case dir
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state"
  printf '%s\n' "$dir"
}

# Run <script> with <flavor>'s stat shadowing the real one (or, for flavor
# "native", with the host's own stat untouched).
run_with_stat() {  # <case-dir> <gnu|bsd|native> <bash -c script>
  local dir=$1 flavor=$2 script=$3 bin
  if [ "$flavor" = native ]; then
    FM_TEST_REAL_STAT="$REAL_STAT" ROOT="$ROOT" bash -c "$script"
    return
  fi
  bin=$(make_stat_shim "$dir" "$flavor")
  PATH="$bin:$PATH" FM_TEST_REAL_STAT="$REAL_STAT" ROOT="$ROOT" bash -c "$script"
}

# Set <file>'s mtime to exactly <epoch> (touch -t takes a local-time stamp on
# both platforms, so convert via BSD `date -r` or GNU `date -d @`).
set_mtime() {  # <epoch> <file>
  local epoch=$1 f=$2 stamp
  if stamp=$(date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null); then
    touch -t "$stamp" "$f"
  else
    stamp=$(date -d "@$epoch" +%Y%m%d%H%M.%S)
    touch -t "$stamp" "$f"
  fi
}

# --- the shims themselves must reproduce the hazard -------------------------

test_gnu_shim_reproduces_the_darwin_name_branch_failure() {
  local dir out rc
  dir=$(make_case gnu-shim-fidelity)
  printf 'x\n' > "$dir/probe"
  # What a `[ "$(uname)" = Darwin ]` branch would run on this host.
  out=$(run_with_stat "$dir" gnu 'stat -f %m "'"$dir"'/probe" 2>/dev/null') && rc=0 || rc=$?
  [ "$rc" != 0 ] || fail "GNU shim accepted the BSD form; the hazard is not reproduced"
  case "$out" in
    *File:*) : ;;
    *) fail "GNU shim did not write a filesystem dump to stdout; got: $out" ;;
  esac
  # And what the forbidden fallback chain would produce: exit ZERO, dump + epoch.
  out=$(run_with_stat "$dir" gnu 'stat -f %m "'"$dir"'/probe" 2>/dev/null || stat -c %Y "'"$dir"'/probe" 2>/dev/null') && rc=0 || rc=$?
  expect_code 0 "$rc" "forbidden fallback chain should exit zero on the shim"
  case "$out" in
    *File:*) : ;;
    *) fail "fallback chain output lost the dump; the hazard is not reproduced" ;;
  esac
  case "$out" in
    *[!0-9]*) : ;;
    *) fail "fallback chain returned a clean epoch; the hazard is not reproduced" ;;
  esac
  # The BSD shim is the mirror control: it must reject the GNU form.
  run_with_stat "$dir" bsd 'stat -c %Y / >/dev/null 2>&1' && fail "BSD shim accepted -c"
  pass "flavor shims reproduce both the GNU-shadowing failure and the BSD control"
}

# --- the owner --------------------------------------------------------------

test_owner_reads_mtime_under_every_stat_flavor() {
  local dir flavor got want f
  dir=$(make_case owner-mtime)
  f="$dir/target"
  printf 'contents\n' > "$f"
  want=$(( $(date +%s) - 4242 ))
  set_mtime "$want" "$f"
  for flavor in gnu bsd native; do
    got=$(run_with_stat "$dir" "$flavor" '. "$ROOT/bin/fm-stat-lib.sh"; fm_stat_mtime "'"$f"'"') \
      || fail "fm_stat_mtime failed under $flavor stat"
    [ "$got" = "$want" ] || fail "fm_stat_mtime under $flavor stat: expected $want, got '$got'"
  done
  pass "fm_stat_mtime returns the exact epoch under GNU, BSD, and native stat"
}

test_owner_refuses_unreadable_paths_instead_of_printing_garbage() {
  local dir flavor out rc
  dir=$(make_case owner-missing)
  for flavor in gnu bsd native; do
    out=$(run_with_stat "$dir" "$flavor" '. "$ROOT/bin/fm-stat-lib.sh"; fm_stat_mtime "'"$dir"'/absent" 2>&1') && rc=0 || rc=$?
    [ "$rc" != 0 ] || fail "fm_stat_mtime succeeded on a missing path under $flavor stat"
    [ -z "$out" ] || fail "fm_stat_mtime printed '$out' for a missing path under $flavor stat"
    out=$(run_with_stat "$dir" "$flavor" '. "$ROOT/bin/fm-stat-lib.sh"; fm_stat_sig "'"$dir"'/absent" 2>&1') && rc=0 || rc=$?
    [ "$rc" != 0 ] || fail "fm_stat_sig succeeded on a missing path under $flavor stat"
    [ -z "$out" ] || fail "fm_stat_sig printed '$out' for a missing path under $flavor stat"
  done
  pass "both readers fail silently rather than emitting a token arithmetic would choke on"
}

test_owner_signature_tracks_changes_under_every_stat_flavor() {
  local dir flavor f before after
  dir=$(make_case owner-sig)
  f="$dir/state/task.status"
  printf 'working: a\n' > "$f"
  for flavor in gnu bsd native; do
    before=$(run_with_stat "$dir" "$flavor" '. "$ROOT/bin/fm-stat-lib.sh"; fm_stat_sig "'"$f"'"') \
      || fail "fm_stat_sig failed under $flavor stat"
    case "$before" in
      ''|*[!0-9.:]*) fail "fm_stat_sig under $flavor stat returned a malformed signature: '$before'" ;;
    esac
    printf 'working: b\n' >> "$f"
    after=$(run_with_stat "$dir" "$flavor" '. "$ROOT/bin/fm-stat-lib.sh"; fm_stat_sig "'"$f"'"') \
      || fail "fm_stat_sig failed under $flavor stat after append"
    [ "$before" != "$after" ] || fail "fm_stat_sig under $flavor stat did not change after an append"
  done
  pass "fm_stat_sig detects an appended status line under GNU, BSD, and native stat"
}

# --- the readers the finding names ------------------------------------------

test_watcher_beacon_age_survives_gnu_stat_shadowing() {
  local dir flavor beat age
  dir=$(make_case beacon-age)
  beat="$dir/state/.last-watcher-beat"
  : > "$beat"
  set_mtime "$(( $(date +%s) - 120 ))" "$beat"
  for flavor in gnu bsd native; do
    age=$(run_with_stat "$dir" "$flavor" \
      'FM_STATE_OVERRIDE="'"$dir"'/state" . "$ROOT/bin/fm-wake-lib.sh"; fm_path_age "'"$beat"'"') \
      || fail "fm_path_age failed under $flavor stat"
    case "$age" in
      ''|*[!0-9]*) fail "fm_path_age under $flavor stat returned a non-numeric age: '$age'" ;;
    esac
    [ "$age" -ge 115 ] && [ "$age" -le 180 ] \
      || fail "fm_path_age under $flavor stat: expected ~120s, got ${age}s (999999 is the unreadable sentinel)"
  done
  pass "watcher beacon age reads ~120s under GNU, BSD, and native stat, never the stale sentinel"
}

test_watcher_beacon_age_reports_the_sentinel_only_when_truly_absent() {
  local dir flavor age
  dir=$(make_case beacon-absent)
  for flavor in gnu bsd native; do
    age=$(run_with_stat "$dir" "$flavor" \
      'FM_STATE_OVERRIDE="'"$dir"'/state" . "$ROOT/bin/fm-wake-lib.sh"; fm_path_age "'"$dir"'/state/.last-watcher-beat"') \
      || fail "fm_path_age failed on an absent beacon under $flavor stat"
    [ "$age" = 999999 ] || fail "absent beacon under $flavor stat should age as 999999, got '$age'"
  done
  pass "an absent beacon still ages as the very-old sentinel under every stat flavor"
}

test_git_lock_age_and_stale_proof_survive_gnu_stat_shadowing() {
  local dir flavor lock age
  dir=$(make_case lock-age)
  lock="$dir/state/index.lock"
  : > "$lock"
  set_mtime "$(( $(date +%s) - 300 ))" "$lock"
  for flavor in gnu bsd native; do
    age=$(run_with_stat "$dir" "$flavor" '. "$ROOT/bin/fm-lock-lib.sh"; fm_lock_age "'"$lock"'"') \
      || fail "fm_lock_age failed under $flavor stat"
    case "$age" in
      ''|*[!0-9]*) fail "fm_lock_age under $flavor stat returned a non-numeric age: '$age'" ;;
    esac
    [ "$age" -ge 295 ] && [ "$age" -le 360 ] \
      || fail "fm_lock_age under $flavor stat: expected ~300s, got ${age}s"
  done
  # A FRESH lock must never be provably stale: an unreadable mtime that aged as
  # "very old" would license removing a lock a live git process still holds.
  : > "$lock"
  for flavor in gnu bsd native; do
    run_with_stat "$dir" "$flavor" \
      'FM_LOCK_LOG_PREFIX=t . "$ROOT/bin/fm-lock-lib.sh"; fm_lock_is_provably_stale "'"$lock"'" "'"$dir"'" 60' 2>/dev/null \
      && fail "a just-created lock was declared provably stale under $flavor stat"
  done
  pass "git lock age is exact and a fresh lock is never provably stale under any stat flavor"
}

test_x_context_registry_timestamp_survives_gnu_stat_shadowing() {
  local dir flavor rec got want
  dir=$(make_case x-registry)
  rec="$dir/state/req.json"
  printf '{"platform":"x","reply_max_chars":280}\n' > "$rec"
  want=$(( $(date +%s) - 900 ))
  set_mtime "$want" "$rec"
  for flavor in gnu bsd native; do
    got=$(run_with_stat "$dir" "$flavor" '. "$ROOT/bin/fm-x-lib.sh"; fmx_context_registry_mtime "'"$rec"'"') \
      || fail "fmx_context_registry_mtime failed under $flavor stat"
    [ "$got" = "$want" ] || fail "fmx_context_registry_mtime under $flavor stat: expected $want, got '$got'"
    run_with_stat "$dir" "$flavor" '. "$ROOT/bin/fm-x-lib.sh"; fmx_context_registry_mtime "'"$dir"'/state/absent.json"' 2>/dev/null \
      && fail "fmx_context_registry_mtime succeeded on a missing record under $flavor stat"
  done
  pass "X reply-context retention timestamps are exact under GNU, BSD, and native stat"
}

test_pause_fingerprint_deadline_tracks_the_event_under_gnu_stat_shadowing() {
  local dir flavor state fresh aged
  dir=$(make_case pause-fingerprint)
  state="$dir/state"
  printf 'paused: waiting on CI\n' > "$state/task.status"
  printf 'window=fm:task\nworktree=%s\n' "$dir" > "$state/task.meta"
  for flavor in gnu bsd native; do
    set_mtime "$(date +%s)" "$state/task.status"
    fresh=$(run_with_stat "$dir" "$flavor" \
      'FM_STATE_OVERRIDE="'"$state"'" . "$ROOT/bin/fm-watch.sh"; pause_class_fingerprint fm:task task') \
      || fail "pause_class_fingerprint failed under $flavor stat"
    set_mtime "$(( $(date +%s) - 7200 ))" "$state/task.status"
    aged=$(run_with_stat "$dir" "$flavor" \
      'FM_STATE_OVERRIDE="'"$state"'" . "$ROOT/bin/fm-watch.sh"; pause_class_fingerprint fm:task task') \
      || fail "pause_class_fingerprint failed under $flavor stat on the aged event"
    [ -n "$fresh" ] && [ -n "$aged" ] || fail "pause_class_fingerprint printed nothing under $flavor stat"
    [ "$fresh" != "$aged" ] \
      || fail "pause fingerprint under $flavor stat ignored the event mtime: a cached pause would never reach its long recheck"
  done
  pass "the pause fingerprint's recheck deadline still tracks the event mtime under every stat flavor"
}

test_x_private_artifact_checks_still_accept_a_valid_artifact() {
  local dir flavor art
  dir=$(make_case x-artifact)
  art="$dir/state/private"
  mkdir -p "$art"
  chmod 700 "$art"
  printf 'secret\n' > "$art/record"
  chmod 600 "$art/record"
  for flavor in gnu bsd native; do
    run_with_stat "$dir" "$flavor" \
      '. "$ROOT/bin/fm-x-lib.sh"; fmx_private_artifact_dir_device "'"$art"'" >/dev/null' \
      || fail "a 0700 private artifact dir was rejected under $flavor stat"
    run_with_stat "$dir" "$flavor" \
      '. "$ROOT/bin/fm-x-lib.sh"; fmx_single_link_file_mode_valid "'"$art"'/record" 600' \
      || fail "a single-link 0600 artifact was rejected under $flavor stat"
    chmod 644 "$art/record"
    run_with_stat "$dir" "$flavor" \
      '. "$ROOT/bin/fm-x-lib.sh"; fmx_single_link_file_mode_valid "'"$art"'/record" 600' \
      && fail "a 0644 artifact was accepted as 0600 under $flavor stat"
    chmod 600 "$art/record"
    ln "$art/record" "$art/hardlink"
    run_with_stat "$dir" "$flavor" \
      '. "$ROOT/bin/fm-x-lib.sh"; fmx_single_link_file_valid "'"$art"'/record"' \
      && fail "a hard-linked artifact was accepted as single-link under $flavor stat"
    rm -f "$art/hardlink"
  done
  pass "X private-artifact mode/link/device checks stay accurate under every stat flavor"
}

test_pr_check_registration_identity_survives_gnu_stat_shadowing() {
  local dir flavor f before after
  dir=$(make_case pr-identity)
  f="$dir/state/task.check.sh"
  printf '#!/bin/sh\nexit 0\n' > "$f"
  chmod 700 "$f"
  for flavor in gnu bsd native; do
    before=$(run_with_stat "$dir" "$flavor" '. "$ROOT/bin/fm-pr-lib.sh"; fm_pr_file_identity "'"$f"'"') \
      || fail "fm_pr_file_identity failed under $flavor stat"
    case "$before" in
      ''|*'?'*) fail "fm_pr_file_identity under $flavor stat returned '$before'" ;;
    esac
    [ "$(run_with_stat "$dir" "$flavor" '. "$ROOT/bin/fm-pr-lib.sh"; fm_pr_file_mode "'"$f"'"')" = 700 ] \
      || fail "fm_pr_file_mode misread a 0700 check under $flavor stat"
    [ "$(run_with_stat "$dir" "$flavor" '. "$ROOT/bin/fm-pr-lib.sh"; fm_pr_file_link_count "'"$f"'"')" = 1 ] \
      || fail "fm_pr_file_link_count misread a single-link check under $flavor stat"
    # A replaced file must change identity; the same file must not.
    after=$(run_with_stat "$dir" "$flavor" '. "$ROOT/bin/fm-pr-lib.sh"; fm_pr_file_identity "'"$f"'"')
    [ "$before" = "$after" ] || fail "fm_pr_file_identity is unstable under $flavor stat"
  done
  pass "PR check registration identity and safety bits read correctly under every stat flavor"
}

test_pending_reply_signature_survives_gnu_stat_shadowing() {
  local dir flavor f before after
  dir=$(make_case pending-signature)
  f="$dir/state/task.status"
  printf 'working: a\n' > "$f"
  for flavor in gnu bsd native; do
    before=$(run_with_stat "$dir" "$flavor" \
      '. "$ROOT/bin/fm-pending-reply-lib.sh"; fm_pending_reply_file_signature "'"$f"'"')
    [ "$before" != unreadable ] \
      || fail "pending-reply signature read as 'unreadable' under $flavor stat"
    [ "$before" != missing ] || fail "pending-reply signature read as 'missing' for a real file"
    printf 'working: b\n' >> "$f"
    after=$(run_with_stat "$dir" "$flavor" \
      '. "$ROOT/bin/fm-pending-reply-lib.sh"; fm_pending_reply_file_signature "'"$f"'"')
    [ "$before" != "$after" ] \
      || fail "pending-reply signature did not change after an append under $flavor stat"
  done
  pass "pending-reply status signatures track real changes under every stat flavor"
}

# --- the class cannot come back ---------------------------------------------

# Code lines only: these files legitimately NAME the forbidden forms in the
# comments that explain why they are forbidden.
code_lines() {  # <file>
  grep -vE '^[[:space:]]*#' "$1"
}

test_supervision_owners_do_not_re_derive_a_stat_flavor() {
  local f offenders=''
  for f in $STAT_OWNERS; do
    [ -e "$ROOT/bin/$f" ] || fail "STAT_OWNERS names a missing file: bin/$f"
    code_lines "$ROOT/bin/$f" | grep -qE 'stat[[:space:]]+-[cf]' \
      && offenders="$offenders bin/$f"
  done
  [ -z "$offenders" ] \
    || fail "these supervision-graph readers invoke stat directly instead of bin/fm-stat-lib.sh:$offenders"
  code_lines "$ROOT/bin/fm-stat-lib.sh" | grep -qE 'stat[[:space:]]+-f.*\|\|.*stat[[:space:]]+-c' \
    && fail "the stat owner itself uses the forbidden fallback chain"
  code_lines "$ROOT/bin/fm-stat-lib.sh" | grep -qE '\buname\b' \
    && fail "the stat owner branches on uname instead of probing the real binary"
  code_lines "$ROOT/bin/fm-stat-lib.sh" | grep -qE 'stat[[:space:]]+-c' \
    || fail "the stat owner never binds the GNU form"
  code_lines "$ROOT/bin/fm-stat-lib.sh" | grep -qE 'stat[[:space:]]+-f' \
    || fail "the stat owner never binds the BSD form"
  pass "every supervision-graph metadata reader routes through the single probe-bound owner"
}

test_gnu_shim_reproduces_the_darwin_name_branch_failure
test_owner_reads_mtime_under_every_stat_flavor
test_owner_refuses_unreadable_paths_instead_of_printing_garbage
test_owner_signature_tracks_changes_under_every_stat_flavor
test_watcher_beacon_age_survives_gnu_stat_shadowing
test_watcher_beacon_age_reports_the_sentinel_only_when_truly_absent
test_git_lock_age_and_stale_proof_survive_gnu_stat_shadowing
test_x_context_registry_timestamp_survives_gnu_stat_shadowing
test_pause_fingerprint_deadline_tracks_the_event_under_gnu_stat_shadowing
test_x_private_artifact_checks_still_accept_a_valid_artifact
test_pr_check_registration_identity_survives_gnu_stat_shadowing
test_pending_reply_signature_survives_gnu_stat_shadowing
test_supervision_owners_do_not_re_derive_a_stat_flavor
