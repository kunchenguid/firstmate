#!/usr/bin/env bash
# Readers of a Windows session lock: the supervision host's main-session key and
# the Claude auto-arm (claim pin, claim read-back, mid-turn health) must accept
# the tagged win:<pid> holder bin/fm-session-lock-lib.sh writes on Git Bash, and
# must still fail closed when that Windows process is gone, is a different
# executable, or the tag appears off Windows. Every untagged value must reach
# the generic numeric helpers unchanged, so POSIX behaviour stays identical.
# shellcheck disable=SC2016 # single quotes are deliberate: each expression expands inside the fixture child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-lock-windows-consumers)

# A Git Bash host as firstmate sees it: uname reports MINGW, Cygwin's ps has no
# -o option and reports every shell's parent as 1, and `ps -W` lists Windows
# processes from FM_TEST_WIN_TABLE in the real column order. Local process
# identity comes from /proc, which Git Bash provides; FM_PROC_ROOT_OVERRIDE
# points it at a per-case tree.
FAKEBIN=$(fm_fakebin "$TMP_ROOT/cygwin-bin")
cat > "$FAKEBIN/uname" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'MINGW64_NT-10.0-26200'
SH
cat > "$FAKEBIN/ps" <<'SH'
#!/usr/bin/env bash
set -u
for a in "$@"; do
  [ "$a" = "-o" ] && { echo "ps: unknown option -- o" >&2; exit 1; }
done
mode=p pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -W) mode=W; shift ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s\n' '      PID    PPID    PGID     WINPID   TTY         UID    STIME COMMAND'
if [ "$mode" = W ]; then
  [ -n "${FM_TEST_WIN_TABLE:-}" ] && printf '%s\n' "$FM_TEST_WIN_TABLE"
  exit 0
fi
printf '%s 1 %s 9999 ? 0 00:00:00 /usr/bin/bash\n' "$pid" "$pid"
SH
# The faked MINGW uname selects GNU `stat -c` for file ages; answer it with the
# host's own stat when the host is BSD-flavoured, so ages stay real.
REAL_STAT=$(command -v stat)
if "$REAL_STAT" -c %Y "$FAKEBIN" >/dev/null 2>&1; then
  ln -s "$REAL_STAT" "$FAKEBIN/stat"
else
  cat > "$FAKEBIN/stat" <<SH
#!/usr/bin/env bash
if [ "\$1" = -c ] && [ "\$2" = %Y ]; then
  shift 2
  exec "$REAL_STAT" -f %m "\$@"
fi
exec "$REAL_STAT" "\$@"
SH
  chmod +x "$FAKEBIN/stat"
fi
chmod +x "$FAKEBIN/uname" "$FAKEBIN/ps"

# WINPID 7204 is the Claude session holding the lock.
WIN_TABLE='  4201508       0       0       7204  ?              0 22:24:48 C:\Users\u\.local\bin\claude.exe
  4198625       0       0       4321  ?              0 22:24:48 C:\Windows\explorer.exe'
# The same Windows pid reissued to an unrelated process.
REUSED_TABLE='  4201508       0       0       7204  ?              0 23:01:10 C:\Windows\notepad.exe'
# The session has exited.
GONE_TABLE='  4198625       0       0       4321  ?              0 22:24:48 C:\Windows\explorer.exe'

# A home whose session lock is held by <lock-value> under session id S1.
make_home() {  # <name> <lock-value>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/proc"
  printf '%s\n' "$2" > "$home/state/.lock"
  printf 'S1\n' > "$home/state/.lock-session"
  printf '%s\n' "$home"
}

# Run <expression> with firstmate's wake and supervision libraries sourced
# against <home>, inside the given environment shape: "windows" puts the Git
# Bash fakes first on PATH, "posix" leaves the host's own tools. The Claude
# session that may be running this suite is scrubbed; the case publishes
# CLAUDE_PID=7204 and CLAUDE_CODE_SESSION_ID=S1 as a Windows Claude session does.
# self_proc gives the expression's own shell a /proc entry so its local
# identity reads as it does on Git Bash. Arguments after <expression> become the
# expression's $0, $1, and so on.
lib_eval() {  # <windows|posix> <home> <expression> [$0 [args...]]
  local shape=$1 home=$2 expr=$3 path=$PATH
  shift 3
  [ "$shape" = windows ] && path="$FAKEBIN:$PATH"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID CLAUDE_CODE_SESSION_ID=S1 CLAUDE_PID=7204 \
    FM_TEST_WIN_TABLE="${FM_TEST_WIN_TABLE:-$WIN_TABLE}" PATH="$path" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$ROOT" \
    FM_PROC_ROOT_OVERRIDE="$home/proc" bash -c '
      self_proc() {
        mkdir -p "$FM_PROC_ROOT_OVERRIDE/$BASHPID"
        printf "%s (bash) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 %s 0 0\n" "$BASHPID" "$BASHPID" \
          > "$FM_PROC_ROOT_OVERRIDE/$BASHPID/stat"
        printf "bash\0-c\0" > "$FM_PROC_ROOT_OVERRIDE/$BASHPID/cmdline"
      }
      . "$FM_ROOT_OVERRIDE/bin/fm-wake-lib.sh" || exit 97
      . "$FM_ROOT_OVERRIDE/bin/fm-supervision-engine-lib.sh" || exit 98
      '"$expr" "$@"
}

test_supervision_main_key_reads_a_windows_session_lock() {
  local home key
  home=$(make_home main-key win:7204)
  key=$(lib_eval windows "$home" 'fm_supervision_host_main_key "$FM_STATE_OVERRIDE"') \
    || fail "the supervision host found no main-session key for a live win:7204 holder"
  case "$key" in
    win:7204:[0-9]*:[0-9]*) ;;
    *) fail "the main-session key did not name the win:7204 holder: '$key'" ;;
  esac
  if FM_TEST_WIN_TABLE="$GONE_TABLE" lib_eval windows "$home" 'fm_supervision_host_main_key "$FM_STATE_OVERRIDE"' >/dev/null; then
    fail "a win:7204 holder that has exited still produced a main-session key"
  fi
  # A pid reissued to another executable is a different holder, so it must not
  # reuse the live session's key.
  reused=$(FM_TEST_WIN_TABLE="$REUSED_TABLE" lib_eval windows "$home" 'fm_supervision_host_main_key "$FM_STATE_OVERRIDE"') || reused=
  [ "$reused" != "$key" ] || fail "a reissued Windows pid kept the live session's main-session key"
  if lib_eval posix "$home" 'fm_supervision_host_main_key "$FM_STATE_OVERRIDE"' >/dev/null; then
    fail "a win: lock was keyed off Windows, where the tag must stay inert"
  fi
  pass "supervision host: a win:<pid> session lock yields the main-session key only while that Windows process lives"
}

test_autoarm_claim_pins_a_windows_lock_holder_and_reads_it_back() {
  local home out
  home=$(make_home claim win:7204)
  out=$(lib_eval windows "$home" '
    self_proc
    fm_autoarm_claim_next "$FM_STATE_OVERRIDE" || { echo claim-failed; exit 0; }
    sed -n "1p;3p" "$FM_STATE_OVERRIDE/.claude-autoarm-epoch"
    if fm_autoarm_claim_open "$FM_STATE_OVERRIDE"; then echo open; else echo closed; fi
    if FM_TEST_WIN_TABLE=$1 fm_autoarm_claim_open "$FM_STATE_OVERRIDE"; then echo reused-open; else echo reused-closed; fi
    if FM_TEST_WIN_TABLE=$2 fm_autoarm_claim_open "$FM_STATE_OVERRIDE"; then echo gone-open; else echo gone-closed; fi
  ' _ "$REUSED_TABLE" "$GONE_TABLE")
  [ "$out" != claim-failed ] || fail "the auto-arm claim failed under a win:7204 lock"
  printf '%s\n' "$out" | sed -n 1p | grep -q 'owner_session_id=S1' \
    || fail "the claim did not record the trusted session id S1: $out"
  [ "$(printf '%s\n' "$out" | sed -n 2p)" = 'win-pid=7204 command=C:/Users/u/.local/bin/claude' ] \
    || fail "the claim did not pin the win:7204 holder's identity: $out"
  [ "$(printf '%s\n' "$out" | sed -n 3p)" = open ] \
    || fail "a claim pinned to the live win:7204 holder did not read back as open: $out"
  [ "$(printf '%s\n' "$out" | sed -n 4p)" = reused-closed ] \
    || fail "a claim stayed open after win:7204 was reissued to another executable: $out"
  [ "$(printf '%s\n' "$out" | sed -n 5p)" = gone-closed ] \
    || fail "a claim stayed open after the win:7204 holder exited: $out"
  pass "auto-arm: a claim pins a win:<pid> lock holder and reads open only while that holder lives"
}

test_autoarm_midturn_health_follows_a_windows_lock_holder() {
  local home out
  home=$(make_home midturn win:7204)
  out=$(lib_eval windows "$home" '
    self_proc
    state=$FM_STATE_OVERRIDE
    : > "$state/.last-watcher-beat"
    fm_recovery_marker_publish "$state/.watcher-down" downtime >/dev/null || { echo marker-failed; exit 0; }
    fm_recovery_marker_read "$state/.watcher-down" || { echo marker-failed; exit 0; }
    recovery=${FM_RECOVERY_MARKER_TOKEN##*:}
    fm_autoarm_claim_next "$state" || { echo claim-failed; exit 0; }
    fm_autoarm_write_owned "$state" "$FM_AUTOARM_MY_GEN" rewake "" win:7204 "$recovery" || { echo write-failed; exit 0; }
    if fm_autoarm_midturn_healthy "$state"; then echo healthy; else echo unhealthy; fi
    if FM_TEST_WIN_TABLE=$1 fm_autoarm_midturn_healthy "$state"; then echo gone-healthy; else echo gone-unhealthy; fi
  ' _ "$GONE_TABLE")
  case "$out" in *-failed*) fail "the mid-turn fixture could not be built: $out" ;; esac
  [ "$(printf '%s\n' "$out" | sed -n 1p)" = healthy ] \
    || fail "a rewake bound to the live win:7204 holder did not read healthy: $out"
  [ "$(printf '%s\n' "$out" | sed -n 2p)" = gone-unhealthy ] \
    || fail "a rewake bound to an exited win:7204 holder still read healthy: $out"
  pass "auto-arm: mid-turn health accepts a rewake bound to a live win:<pid> holder and drops it when that holder exits"
}

test_untagged_values_reach_the_numeric_helpers_unchanged() {
  local home live dead out
  home=$(make_home parity 1)
  sleep 300 &
  live=$!
  sh -c 'exit 0' &
  dead=$!
  wait "$dead" 2>/dev/null || true
  out=$(lib_eval posix "$home" '
    _fm_wake_require_session_lock
    for v in "$1" "$2" "" abc 12x win:7204; do
      a=$(fm_session_pid_identity "$v" 2>&1); ra=$?
      b=$(fm_pid_identity "$v" 2>&1); rb=$?
      [ "$ra:$a" = "$rb:$b" ] || echo "identity-diverged value=[$v] session=[$ra:$a] generic=[$rb:$b]"
      fm_session_pid_alive "$v"; ra=$?
      fm_pid_alive "$v"; rb=$?
      [ "$ra" = "$rb" ] || echo "alive-diverged value=[$v] session=$ra generic=$rb"
    done
    fm_session_pid_identity "$1" >/dev/null || echo live-identity-missing
    fm_session_pid_alive "$1" || echo live-not-alive
  ' _ "$live" "$dead")
  kill "$live" 2>/dev/null
  wait "$live" 2>/dev/null || true
  [ -z "$out" ] || fail "an untagged lock value did not reach the numeric helpers unchanged: $out"
  pass "untagged lock values: the session-pid helpers answer exactly as fm_pid_identity and fm_pid_alive do"
}

test_untagged_values_reach_the_numeric_helpers_unchanged
test_supervision_main_key_reads_a_windows_session_lock
test_autoarm_claim_pins_a_windows_lock_holder_and_reads_it_back
test_autoarm_midturn_health_follows_a_windows_lock_holder
