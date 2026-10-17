#!/usr/bin/env bash
# tests/fm-fork-free-helpers.test.sh - the pure-bash stand-ins that the
# watcher, drain, and lock paths use instead of forking small external
# commands every cycle. Each case compares the helper with the command it
# replaces on the same input, under every available Bash (stock macOS
# /bin/bash 3.2 included) and under both the C and a UTF-8 locale, so an edge
# case where the two disagree fails here instead of drifting silently.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-fork-free-helpers)

# Every distinct Bash this host offers: the running one, stock /bin/bash, and
# whatever `bash` resolves to on PATH.
test_interpreters() {
  local seen='' candidate version
  for candidate in "${BASH:-bash}" /bin/bash "$(command -v bash 2>/dev/null || true)"; do
    [ -n "$candidate" ] && [ -x "$candidate" ] || continue
    # shellcheck disable=SC2016 # Expanded by the candidate interpreter.
    version=$("$candidate" -c 'printf "%s" "$BASH_VERSION"' 2>/dev/null) || continue
    case " $seen " in *" $version "*) continue ;; esac
    seen="$seen $version"
    printf '%s\n' "$candidate"
  done
}

test_locales() {
  printf '%s\n' C
  if locale -a 2>/dev/null | grep -qx 'C.UTF-8'; then
    printf '%s\n' C.UTF-8
  elif locale -a 2>/dev/null | grep -qx 'en_US.UTF-8'; then
    printf '%s\n' en_US.UTF-8
  fi
}

# Run <script> under every interpreter and locale; any output is a mismatch
# report and fails the case.
run_everywhere() {  # <label> <script> [args...]
  local label=$1 script=$2 interpreter loc out
  shift 2
  while IFS= read -r interpreter; do
    while IFS= read -r loc; do
      out=$(LC_ALL=$loc FM_STATE_OVERRIDE="$TMP_ROOT/state" "$interpreter" "$script" "$ROOT" "$@" 2>&1) \
        || fail "$label failed under $interpreter ($loc): $out"
      [ -z "$out" ] || fail "$label differs under $interpreter ($loc):"$'\n'"$out"
    done < <(test_locales)
  done < <(test_interpreters)
}

test_path_helpers_match_dirname_and_basename() {
  local script="$TMP_ROOT/paths.sh" cases="$TMP_ROOT/path-cases"
  # NUL-separated so paths may carry newlines.
  printf '%s\0' '' / // /// a a/ a// /a /a/ //a a/b a/b/ a//b //a//b/ . .. ./ ../x \
    'a b/c d' 'a/-x' $'a\n/b' $'a/b\n' $'x\n' $'a/b\n\n' $'a\n' $'\n' $'/\n' $'a/\n/' \
    'state/crew.status' '/abs/state/.seen-x' 'x.y.z/.status' '*/?' 'a/[b]' \
    $'caf\xc3\xa9/\xc3\xbc.status' $'\xff\xfe/\xc3.x' $'a/\xff/' > "$cases"
  cat > "$script" <<'SH'
. "$1/bin/fm-wake-lib.sh"
while IFS= read -r -d '' p; do
  fm_dirname_to got "$p"
  want=$(dirname -- "$p")
  [ "$got" = "$want" ] || printf 'dirname %q: helper %q, command %q\n' "$p" "$got" "$want"
  fm_basename_to got "$p"
  want=$(basename -- "$p")
  [ "$got" = "$want" ] || printf 'basename %q: helper %q, command %q\n' "$p" "$got" "$want"
done < "$2"
SH
  run_everywhere "path helpers" "$script" "$cases"
  pass "fm_dirname_to and fm_basename_to match dirname and basename on every edge case"
}

test_epoch_helper_matches_date_and_never_forks_more() {
  local script="$TMP_ROOT/epoch.sh" shim="$TMP_ROOT/epoch-shim" log="$TMP_ROOT/epoch-date.log"
  mkdir -p "$shim"
  cat > "$shim/date" <<SH
#!/bin/sh
printf 'date\n' >> "$log"
exec $(command -v date) "\$@"
SH
  chmod +x "$shim/date"
  # shellcheck disable=SC2016 # Expanded by the child shell.
  printf '%s\n' '. "$1/bin/fm-wake-lib.sh"' \
    'PATH="$2:$PATH"' \
    ': > "$3"' \
    'before=$(/bin/date +%s)' \
    'fm_epoch_seconds_to now' \
    'after=$(/bin/date +%s)' \
    'case "$now" in ""|*[!0-9]*) printf "not epoch seconds: %q\n" "$now" ;; esac' \
    '[ "$now" -ge "$before" ] && [ "$now" -le "$after" ] || printf "%s outside [%s, %s]\n" "$now" "$before" "$after"' \
    'forks=$(grep -c . "$3" || true)' \
    'if [ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }; then' \
    '  [ "$forks" -eq 0 ] || printf "bash %s ran date %s times\n" "$BASH_VERSION" "$forks"' \
    'else' \
    '  [ "$forks" -eq 1 ] || printf "bash %s ran date %s times, not exactly once\n" "$BASH_VERSION" "$forks"' \
    'fi' > "$script"
  run_everywhere "epoch helper" "$script" "$shim" "$log"
  pass "fm_epoch_seconds_to reads the clock like date +%s and forks date at most as often"
}

test_signal_seen_path_and_lock_abs_path_are_unchanged() {
  local script="$TMP_ROOT/seen.sh" dir="$TMP_ROOT/lockdir"
  mkdir -p "$dir/sub" "$TMP_ROOT/state"
  cat > "$script" <<'SH'
. "$1/bin/fm-wake-lib.sh"
state=$2
for f in "$state/crew.status" "$state/a.b.c.status" "state/x.status" ".status" \
  "$state/crew.turn-ended" "$state/dir/" "x" "a.b/" "/" "$state/q.status.bak"; do
  got=$(fm_wake_signal_seen_path "$state" "$f")
  case "$f" in
    *.status)
      task=$(basename "$f"); task=${task%.status}
      want=$(printf '%s/.seen-%s' "$state" "$(printf '%s.status' "$task" | tr '.' '_')")
      ;;
    *) want=$(printf '%s/.seen-%s' "$state" "$(basename "$f" | tr '.' '_')") ;;
  esac
  [ "$got" = "$want" ] || printf 'seen path %q: helper %q, commands %q\n' "$f" "$got" "$want"
done
cd "$3" || exit 1
for p in "$3/x.lock" "$3/sub/x.lock" "$3//sub//x.lock" "sub/x.lock" "x.lock" "sub/x.lock/" "./sub/../x.lock"; do
  got=$(fm_lock_abs_path "$p")
  want="$(cd "$(dirname "$p")" && pwd -P)/$(basename "$p")"
  [ "$got" = "$want" ] || printf 'lock path %q: helper %q, commands %q\n' "$p" "$got" "$want"
done
SH
  run_everywhere "seen and lock paths" "$script" "$TMP_ROOT/state" "$dir"
  pass "signal seen paths and absolute lock paths are byte-identical to the dirname/basename/tr forms"
}

test_recovery_marker_read_accepts_exactly_one_newline() {
  local script="$TMP_ROOT/marker.sh" cases="$TMP_ROOT/marker-cases"
  mkdir -p "$cases"
  printf 'pending:handling:g1\n' > "$cases/one"
  printf 'pending:handling:g1' > "$cases/unterminated"
  printf 'pending:handling:g1\npending:handling:g2\n' > "$cases/two"
  printf 'pending:handling:g1\ntrailing-partial' > "$cases/partial-second"
  : > "$cases/empty"
  printf '\n' > "$cases/blank"
  printf 'announced:downtime:g\0x\n' > "$cases/nul"
  printf 'acked:handling:g1\r\n' > "$cases/crlf"
  printf 'pending:handling:g1\n\n' > "$cases/blank-second"
  cat > "$script" <<'SH'
. "$1/bin/fm-wake-lib.sh"
for marker in "$2"/*; do
  # The replaced reference: one newline byte by wc -l, then the same token read.
  want=reject
  if [ "$(wc -l < "$marker" | tr -d '[:space:]')" = 1 ] && IFS= read -r line < "$marker"; then
    case "$line" in
      pending:handling:*|pending:downtime:*|announced:handling:*|announced:downtime:*|acked:handling:*|acked:downtime:*)
        case "${line##*:}" in ''|*[!A-Za-z0-9._-]*) ;; *) want="accept:$line" ;; esac ;;
    esac
  fi
  if fm_recovery_marker_read "$marker"; then got="accept:$FM_RECOVERY_MARKER_TOKEN"; else got=reject; fi
  [ "$got" = "$want" ] || printf 'marker %s: helper %q, reference %q\n' "${marker##*/}" "$got" "$want"
done
SH
  run_everywhere "recovery marker read" "$script" "$cases"
  pass "recovery marker reads accept exactly the one-line records wc -l accepted"
}

test_window_to_task_matches_the_meta_pipeline() {
  local script="$TMP_ROOT/window.sh" state="$TMP_ROOT/window-state"
  mkdir -p "$state"
  printf 'window=sess:w1\nbackend=tmux\n' > "$state/alpha.meta"
  printf 'window=old\nwindow=sess:w2\n' > "$state/beta.meta"
  printf 'terminal=term-3\nwindow=\n' > "$state/gamma.meta"
  printf 'window=a=b=c' > "$state/delta.meta"
  printf 'window=sess:w5\r\n' > "$state/eps.meta"
  printf ' window=sess:w6\nwindow= sess:w6 \n' > "$state/zeta.meta"
  printf 'terminal=t7\nterminal=\n' > "$state/eta.meta"
  mkdir -p "$state/dir.meta"
  printf 'window=sess:w9\n' > "$state/theta.meta"
  chmod 000 "$state/theta.meta"
  cat > "$script" <<'SH'
. "$1/bin/fm-classify-lib.sh"
state=$2
reference() {  # the replaced grep | tail -1 | cut -d= -f2- lookup
  local w=$1 meta mw mt t
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    mw=$(grep '^window=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    mt=$(grep '^terminal=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    [ "$mw" = "$w" ] || [ "$mt" = "$w" ] || continue
    t=$(basename "$meta"); printf '%s' "${t%.meta}"; return 0
  done
  t="${w##*:}"; t="${t#fm-}"; printf '%s' "$t"
}
for w in sess:w1 old sess:w2 term-3 '' a=b=c a sess:w5 $'sess:w5\r' ' sess:w6 ' sess:w6 t7 sess:w9 sess:fm-fallback-x unknown; do
  got=$(window_to_task "$w" "$state")
  want=$(reference "$w")
  [ "$got" = "$want" ] || printf 'window %q: helper %q, pipeline %q\n' "$w" "$got" "$want"
done
SH
  run_everywhere "window_to_task" "$script" "$state"
  chmod 600 "$state/theta.meta"
  pass "window_to_task resolves every recorded window exactly as the grep/tail/cut pipeline did"
}

test_classify_stat_helpers_read_the_kernel_name_once() {
  local script="$TMP_ROOT/uname.sh" shim="$TMP_ROOT/uname-shim" log="$TMP_ROOT/uname.log" file="$TMP_ROOT/sized"
  mkdir -p "$shim"
  cat > "$shim/uname" <<SH
#!/bin/sh
printf 'uname\n' >> "$log"
exec $(command -v uname) "\$@"
SH
  chmod +x "$shim/uname"
  printf 'caf\303\251 bytes\n' > "$file"
  cat > "$script" <<'SH'
PATH="$2:$PATH"
: > "$3"
. "$1/bin/fm-classify-lib.sh"
for _ in 1 2 3 4 5; do
  size=$(_fm_status_file_size "$4")
  [ "$size" = "$(LC_ALL=C wc -c < "$4" | tr -d ' ')" ] || printf 'size %q\n' "$size"
  mtime=$(_fm_status_file_mtime "$4")
  case "$mtime" in ''|*[!0-9]*) printf 'mtime %q\n' "$mtime" ;; esac
  _fm_open_decisions_file_ident "$4" >/dev/null || printf 'identity unreadable\n'
done
calls=$(grep -c . "$3" || true)
[ "$calls" -eq 1 ] || printf 'uname ran %s times for 15 stat reads\n' "$calls"
SH
  run_everywhere "classify stat helpers" "$script" "$shim" "$log" "$file"
  pass "classify stat helpers resolve the kernel name once per process"
}

test_read_file_helper_matches_cat() {
  local script="$TMP_ROOT/read.sh" cases="$TMP_ROOT/read-cases"
  mkdir -p "$cases/dir"
  printf '123\n' > "$cases/pid"
  printf '123\n456\n' > "$cases/two"
  printf 'ab\0cd\n\n' > "$cases/nul"
  printf '\0\0' > "$cases/nuls"
  printf '' > "$cases/empty"
  printf '\n\n\n' > "$cases/newlines"
  printf 'x\r\n' > "$cases/crlf"
  printf 'tail' > "$cases/unterminated"
  printf ' 12 \n' > "$cases/spaces"
  printf 'caf\303\251 \377\n' > "$cases/bytes"
  printf 'secret\n' > "$cases/unreadable"
  chmod 000 "$cases/unreadable"
  cat > "$script" <<'SH'
. "$1/bin/fm-path-lib.sh"
for f in "$2"/* "$2/missing"; do
  # Bash 4.4+ warns on the NUL bytes the substitution drops.
  { want=$(cat "$f" 2>/dev/null); want_rc=$?; } 2>/dev/null
  fm_read_file_to got "$f"; got_rc=$?
  [ "$got" = "$want" ] && [ "$got_rc" = "$want_rc" ] \
    || printf 'read %s: helper %q (%s), cat %q (%s)\n' "${f##*/}" "$got" "$got_rc" "$want" "$want_rc"
  nul=0; { [ "$(LC_ALL=C tr -d '\000' < "$f" | wc -c)" = "$(wc -c < "$f")" ] || nul=1; } 2>/dev/null
  [ ! -r "$f" ] || [ -d "$f" ] || [ "$FM_READ_FILE_NUL" = "$nul" ] \
    || printf 'read %s: NUL flag %s, expected %s\n' "${f##*/}" "$FM_READ_FILE_NUL" "$nul"
done
SH
  run_everywhere "read helper" "$script" "$cases"
  chmod 600 "$cases/unreadable"
  pass "fm_read_file_to assigns and returns exactly what a cat command substitution does"
}

test_harness_name_match_agrees_with_grep() {
  local script="$TMP_ROOT/harness-re.sh" cases="$TMP_ROOT/harness-re-cases"
  printf '%s\0' '' claude claude-code /x/claude codex opencode grok kimi pi pi-signed pix xpi omp ompd comp \
    node bash 'node /opt/claude/cli.js' 'python -m kimi' 'CLAUDE' $'claude\nx' $'x\npi' $'pi\n' \
    $'caf\xc3\xa9 claude' $'\xff omp' $'pi\xc3\xa9' '2.1.220' '/u/.local/share/claude/versions/2.1.220' > "$cases"
  cat > "$script" <<'SH'
. "$1/bin/fm-session-lock-lib.sh"
while IFS= read -r -d '' s; do
  if _fm_harness_re_matches "$s"; then got=1; else got=0; fi
  if printf '%s' "$s" | grep -qE "$FM_HARNESS_RE"; then want=1; else want=0; fi
  [ "$got" = "$want" ] || printf 'harness re %q: helper %s, grep %s\n' "$s" "$got" "$want"
done < "$2"
SH
  run_everywhere "harness name match" "$script" "$cases"
  pass "the in-process harness name match agrees with grep -E on every case"
}

test_cursor_fast_negative_never_hides_a_cursor_path() {
  local script="$TMP_ROOT/cursor.sh" tree="$TMP_ROOT/cursor-tree"
  mkdir -p "$tree/share/cursor-agent/versions/1.2/" "$tree/bin" "$tree/plain/sub" "$tree/Cursor-Agent"
  printf '#!/bin/sh\n' > "$tree/share/cursor-agent/versions/1.2/cursor-agent"
  printf '#!/bin/sh\n' > "$tree/plain/sub/node"
  printf '#!/bin/sh\n' > "$tree/Cursor-Agent/agent"
  ln -s "$tree/share/cursor-agent/versions/1.2/cursor-agent" "$tree/bin/agent"
  ln -s ../share/cursor-agent/versions/1.2 "$tree/bin/versions"
  ln -s "$tree/share" "$tree/linked-share"
  cat > "$script" <<'SH'
. "$1/bin/fm-cursor-lib.sh"
t=$2
reference() {  # the canonicalizing check without the fast negative
  local canonical
  canonical=$(fm_cursor_canonical_path "$1") || return 1
  case "${canonical##*/}" in cursor-agent) return 0 ;; esac
  case "$canonical" in */cursor-agent/versions/*/*) return 0 ;; esac
  return 1
}
for p in "$t/bin/agent" "$t/bin/versions/cursor-agent" "$t/linked-share/cursor-agent/versions/1.2/cursor-agent" \
  "$t/share/cursor-agent/versions/1.2/cursor-agent" "$t/plain/sub/node" "$t/plain/./sub/../sub/node" \
  "$t//plain//sub/node" "$t/plain/missing/x" "$t/CURSOR-AGENT/agent" "$t/Cursor-Agent/agent" \
  /bin/bash /usr/bin/env "plain/sub/node" "$t/plain/sub/"; do
  if fm_cursor_path_is_cursor "$p"; then got=1; else got=0; fi
  if reference "$p"; then want=1; else want=0; fi
  [ "$got" = "$want" ] || printf 'cursor path %q: helper %s, canonical %s\n' "$p" "$got" "$want"
done
SH
  run_everywhere "cursor fast negative" "$script" "$tree"
  pass "the Cursor path fast negative agrees with full canonicalization, symlinks and case included"
}

test_ancestry_hop_reads_match_separate_ps_calls() {
  local script="$TMP_ROOT/hop.sh"
  cat > "$script" <<'SH'
. "$1/bin/fm-session-lock-lib.sh"
n=0
for pid in $$ $PPID 1 $(ps -A -o pid= 2>/dev/null | head -40); do
  want_comm=$(ps -o comm= -p "$pid" 2>/dev/null) || continue
  want_ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  _fm_harness_ps_hop "$pid" || { printf 'hop %s failed\n' "$pid"; continue; }
  [ "$FM_HARNESS_HOP_COMM" = "$want_comm" ] || printf 'hop %s comm %q, ps %q\n' "$pid" "$FM_HARNESS_HOP_COMM" "$want_comm"
  [ -z "$FM_HARNESS_HOP_PPID" ] || [ "$FM_HARNESS_HOP_PPID" = "$want_ppid" ] \
    || printf 'hop %s ppid %q, ps %q\n' "$pid" "$FM_HARNESS_HOP_PPID" "$want_ppid"
  n=$((n + 1))
done
[ "$n" -gt 0 ] || printf 'no process could be read\n'
SH
  run_everywhere "ancestry hop" "$script"
  pass "one combined ps read per ancestry hop reports the same parent and command name as separate reads"
}

test_ancestry_walk_reads_arguments_only_when_needed() {
  local script="$TMP_ROOT/walk.sh" shim="$TMP_ROOT/walk-shim" log="$TMP_ROOT/walk-ps.log"
  mkdir -p "$shim"
  # A deterministic table: the caller ($$) is bash under 800 (zsh), under two
  # nested claude processes, under launchd.
  cat > "$shim/ps" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
fields='' pid=''
while [ "\$#" -gt 0 ]; do
  case "\$1" in -o) fields="\$fields \$2"; shift 2 ;; -p) pid=\$2; shift 2 ;; *) shift ;; esac
done
case "\$pid" in
  800) ppid=700 comm=zsh args='zsh -i' ;;
  700) ppid=600 comm=claude args='claude --resume' ;;
  600) ppid=1 comm=/opt/claude/versions/2.1.220 args='/opt/claude/versions/2.1.220' ;;
  1) ppid=0 comm=launchd args=launchd ;;
  *) ppid=800 comm=bash args='bash hook.sh' ;;
esac
line=''
for f in \$fields; do
  case "\$f" in ppid=) line="\$line \$ppid" ;; comm=) line="\$line \$comm" ;; args=) line="\$line \$args" ;; esac
done
printf '%s\n' "\${line# }"
SH
  chmod +x "$shim/ps"
  cat > "$script" <<'SH'
PATH="$2:$PATH"
. "$1/bin/fm-session-lock-lib.sh"
kill() { return 0; }
: > "$3"
got=$(fm_harness_ancestry_pids | tr '\n' ' ')
[ "$got" = "700 600 " ] || printf 'ancestry %q, expected the two claude pids\n' "$got"
calls=$(grep -c . "$3" || true)
# Hops: caller, 800, 700, 600, 1 -> one combined read each; argument reads only
# for the three names (bash, zsh, launchd) the command name alone cannot decide.
[ "$calls" -le 8 ] || printf 'ancestry walk ran ps %s times, more than 8\n' "$calls"
args=$(grep -c 'args=' "$3" || true)
[ "$args" -le 3 ] || printf 'ancestry walk read arguments %s times, more than 3\n' "$args"
SH
  run_everywhere "ancestry walk forks" "$script" "$shim" "$log"
  pass "the ancestry walk reads each hop once and reads arguments only when the command name cannot decide"
}

test_ledger_outcome_and_identity_match_sed() {
  local script="$TMP_ROOT/ledger.sh" cases="$TMP_ROOT/ledger-cases"
  mkdir -p "$cases"
  printf 'epoch=3 owner_pid=1 outcome=rewake updated_at=9\nidentity line\n' > "$cases/rewake"
  printf 'epoch=3 owner_pid=1 outcome=failed-suppressed updated_at=9\n' > "$cases/suppressed"
  printf 'epoch=3 outcome=arming\n' > "$cases/last-field"
  printf 'epoch=3 outcome=Bad x\n' > "$cases/upper"
  printf 'outcome=a outcome=b c\n' > "$cases/twice"
  printf 'epoch=3 outcome=rewake \r\n' > "$cases/crlf"
  printf 'epoch=3 outcome=rew\0ake x\n' > "$cases/nul"
  printf 'epoch=3 outcome=caf\303\251 x\n' > "$cases/utf8"
  printf 'epoch=3 outcome=\377x y\n' > "$cases/invalid"
  printf '\nepoch=3 outcome=rewake x\n' > "$cases/blank-first"
  printf 'epoch=3 outcome=rewake x' > "$cases/unterminated"
  printf 'epoch=3 owner_pid=1 outcome=arming x\nid\0x\nthird\n' > "$cases/identity-nul"
  printf 'epoch=3 owner_pid=1 outcome=arming x\n\n' > "$cases/identity-blank"
  : > "$cases/empty"
  for f in "$cases"/*; do mkdir -p "$f.d"; cp "$f" "$f.d/.claude-autoarm-epoch"; done
  mkdir -p "$cases/missing.d"
  cat > "$script" <<'SH'
. "$1/bin/fm-wake-lib.sh"
for d in "$2"/*.d; do
  f="$d/.claude-autoarm-epoch"
  want=$(sed -n '1s/^.*outcome=\([a-z][a-z-]*\) .*$/\1/p' "$f" 2>/dev/null || true)
  got=unset
  fm_autoarm_ledger_outcome_to got "$d"
  [ "$got" = "$want" ] || printf 'outcome %s: helper %q, sed %q\n' "${d##*/}" "$got" "$want"
  if fm_autoarm_ledger_read "$d"; then
    # Bash 4.4+ warns on the NUL bytes the substitution drops.
    { want=$(sed -n '2p' "$f" 2>/dev/null || true); } 2>/dev/null
    [ "$FM_AUTOARM_IDENTITY" = "$want" ] \
      || printf 'identity %s: helper %q, sed %q\n' "${d##*/}" "$FM_AUTOARM_IDENTITY" "$want"
  fi
done
SH
  run_everywhere "ledger reads" "$script" "$cases"
  pass "the ledger outcome and identity reads match the sed expressions they replace"
}

if [ -n "${FM_TEST_ONLY:-}" ]; then
  "$FM_TEST_ONLY"
else
  test_path_helpers_match_dirname_and_basename
  test_epoch_helper_matches_date_and_never_forks_more
  test_signal_seen_path_and_lock_abs_path_are_unchanged
  test_recovery_marker_read_accepts_exactly_one_newline
  test_window_to_task_matches_the_meta_pipeline
  test_classify_stat_helpers_read_the_kernel_name_once
  test_read_file_helper_matches_cat
  test_harness_name_match_agrees_with_grep
  test_cursor_fast_negative_never_hides_a_cursor_path
  test_ancestry_hop_reads_match_separate_ps_calls
  test_ancestry_walk_reads_arguments_only_when_needed
  test_ledger_outcome_and_identity_match_sed
fi
