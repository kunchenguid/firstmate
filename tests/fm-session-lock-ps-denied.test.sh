#!/usr/bin/env bash
# tests/fm-session-lock-ps-denied.test.sh - the ps-free identity route.
#
# An EDR-style policy can deny the ps BINARY's exec (verified on a hardened
# macOS host: /bin/ps refused even `ps -V`, while kill/head/sysctl/pgrep/lsof
# ran), and before bin/fm-session-lock-lib.sh could fall back to an OS
# provider, that turned every session into a permanent lock-refused
# read-only one, because identity proof walked ancestry through ps.
#
# The unit cases drive the library behind a deterministic fake ps that
# refuses to run (exit 126, bash's refused-exec status) plus a fake OS
# provider, covering the fallback decision table on any host. The e2e case
# blocks ps from a REAL process tree (fake ps on PATH) and resolves a real
# pid through the REAL platform provider, so a regression that only fakes
# would miss is caught here.
# shellcheck disable=SC2016 # single quotes are deliberate where they expand inside the fixture child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-lock-ps-denied)

LIB="$ROOT/bin/fm-session-lock-lib.sh"

# A denied ps: refuses to run at all, exactly like the blocked binary.
make_denied_ps() {  # <fakebin>
  local fakebin=$1
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
echo "$0: Operation not permitted" >&2
exit 126
SH
  chmod +x "$fakebin/ps"
}

# Run one library expression with a denied ps shadowing PATH and a table
# provider. The table reads FM_TEST_TRIPLE_N records (fake table rows
# "<pid>|<ppid>|<comm>|<args>"); a pid absent from the table is unreadable,
# which is how a dead pid behaves. FM_TEST_KILL_RC decides kill as before.
# CLAUDE identity envs are scrubbed the same way the ancestry suite scrubs
# them, so a suite running inside a real Claude session cannot leak in.
lib_eval_denied() {  # <fakebin> <provider-table-file> <expression>
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_PROVIDER_FILE="$2" PATH="$1:$PATH" bash -c "
    . \"\$0\"
    kill() { return \${FM_TEST_KILL_RC:-0}; }
    _emit_row() {  # <row>
      local ppid rest comm args
      ppid=\${1#*|}; ppid=\${ppid%%|*}
      rest=\${1#*|}; rest=\${rest#*|}
      comm=\${rest%%|*}
      args=\${rest#*|}
      printf '%s\t%s\t%s\n' \"\$ppid\" \"\$comm\" \"\$args\"
    }
    fm_os_proc_triple() {
      local row
      while IFS= read -r row; do
        case \"\$row\" in
          \"\$1|\"*) _emit_row \"\$row\"; return 0 ;;
        esac
      done < \"\$FM_PROVIDER_FILE\"
      while IFS= read -r row; do
        case \"\$row\" in
          \"default|\"*) _emit_row \"\$row\"; return 0 ;;
        esac
      done < \"\$FM_PROVIDER_FILE\"
      return 1
    }
    $3
  " "$LIB"
}

make_table() {  # a version-free claude session at 700, under launchd; any
  # other pid (the child bash the walk starts from) reports bash -> 700.
  # Args stay neutral: a real-looking bash -c command naming python3 and a
  # lib path would be matched as "interpreter running a harness script",
  # which is the matcher being honest, not a bug.
  local file="$TMP_ROOT/table.$$"
  cat > "$file" <<'ROWS'
700|1|claude|claude --resume
1|0|launchd|/sbin/launchd
default|700|bash|bash run.sh
ROWS
  printf '%s\n' "$file"
}

# --- the fallback decision table ---------------------------------------------

test_denied_route_fields_parse_exactly() {
  # Pin every field the 126-route parse produces. The original table rows
  # named claude in both identity fields, so a parse that swapped comm
  # and args, or shifted a field, still passed the walk tests. An
  # asymmetric record plus per-field assertions is what fails such a
  # regression here.
  local dir fakebin table got
  dir="$TMP_ROOT/fields"
  fakebin=$(fm_fakebin "$dir"); make_denied_ps "$fakebin"
  table="$dir/t"
  cat > "$table" <<'ROWS'
700|1|claude|/opt/tools/x --resume
ROWS
  got=$(lib_eval_denied "$fakebin" "$table" \
    'fm_proc_info 700 && printf "%s|%s|%s\n" "$FM_PROC_PPID" "$FM_PROC_COMM" "$FM_PROC_ARGS"') \
    || fail "126-route fm_proc_info refused a well-formed record"
  [ "$got" = "1|claude|/opt/tools/x --resume" ] \
    || fail "126-route parse produced '$got', expected '1|claude|/opt/tools/x --resume'"
  # A record whose ppid field is empty is malformed even when the rest
  # reads fine, and must be refused rather than carried as a blank id.
  cat > "$table" <<'ROWS'
5||bash|bash x
ROWS
  if lib_eval_denied "$fakebin" "$table" 'fm_proc_info 5' >/dev/null 2>&1; then
    fail "126-route accepted a record with an empty ppid field"
  fi
  pass "126-route parse assigns each field and refuses a blank ppid"
}

check_shape_rejected() {  # <dir> <fakebin> <label> <record-bytes>
  local bad="$1/bad"
  printf '%b' "$4" > "$bad"
  if FM_BAD_TRIPLE="$bad" lib_eval_denied "$2" "$1/t" \
    'fm_os_proc_triple() { cat "$FM_BAD_TRIPLE"; return 0; }; fm_proc_info 700' \
    >/dev/null 2>&1; then
    fail "provider record shape '$3' was accepted instead of refused"
  fi
}

test_provider_shape_violations_rejected() {
  # The 126-route parser defines one record: one line, exactly three
  # TAB-separated fields, a numeric ppid. Each record below is a shape a
  # broken or future provider might emit; every one must stop the walk,
  # never half-parse into a plausible but wrong identity.
  #
  # The field COUNT is what these pin, not the field CONTENT: a record
  # whose comm or args field is legitimately empty is a real answer
  # about a real process (a live process whose comm was emptied, a
  # kernel thread with no cmdline), and both routes have to agree on
  # that. A record with a MISSING field is off-spec and is refused.
  local dir fakebin
  dir="$TMP_ROOT/shape"
  fakebin=$(fm_fakebin "$dir"); make_denied_ps "$fakebin"
  : > "$dir/t"
  check_shape_rejected "$dir" "$fakebin" 'two-field' '700\tclaude\n'
  check_shape_rejected "$dir" "$fakebin" 'one-field' '700\n'
  check_shape_rejected "$dir" "$fakebin" 'newline-payload' '700\tclaude\tok\nmore\n'
  check_shape_rejected "$dir" "$fakebin" 'four-field' '700\tclaude\tclaude --resume\tx\n'
  check_shape_rejected "$dir" "$fakebin" 'non-numeric-ppid' 'abc\tclaude\tclaude --resume\n'
  check_shape_rejected "$dir" "$fakebin" 'empty-ppid' '\tclaude\tclaude --resume\n'
  pass "provider records off the defined shape are refused, not parsed"
}

test_provider_empty_field_is_a_present_pid() {
  # A record whose comm field is empty is a PRESENT process, not a
  # malformed record. The ps route reports the same thing for a live
  # process whose comm was emptied, so the two routes must agree: both
  # report the pid as present, and neither reports it as reclaimable.
  local dir fakebin got rc
  dir="$TMP_ROOT/empty-field"
  fakebin=$(fm_fakebin "$dir"); make_denied_ps "$fakebin"
  # Only the empty-comm row: the fake provider answers the first row
  # whose pid matches, so a matching non-empty row would shadow it.
  cat > "$dir/t" <<'ROWS'
700|1||claude --resume
ROWS
  got=$(lib_eval_denied "$fakebin" "$dir/t" \
    'fm_proc_info 700 && printf "%s|%s|%s" "$FM_PROC_PPID" "$FM_PROC_COMM" "$FM_PROC_ARGS"') \
    || fail "a present pid with an empty comm was refused"
  [ "$got" = "1||claude --resume" ] \
    || fail "the empty-comm record produced '$got', expected '1||claude --resume'"
  pass "a provider record with an empty comm field reports a present pid"
}

test_ps_failure_statuses_route_correctly() {
  # ps exit 1 is "ps ran and this pid gives no answer" - a refusal that
  # must pass through as a stop WITHOUT consulting the OS provider.
  # Only a ps that cannot execute at all (126/127) may route to it.
  local dir fakebin calls rc
  dir="$TMP_ROOT/rc-contract"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
exit "${FM_TEST_PS_RC:-1}"
SH
  chmod +x "$fakebin/ps"
  calls="$dir/provider-calls"
  : > "$calls"
  rc=0
  FM_TEST_PS_RC=1 FM_MARKER_FILE="$calls" PATH="$fakebin:$PATH" bash -c '
    . "$0"
    fm_os_proc_triple() { printf "called\n" >> "$FM_MARKER_FILE"; return 1; }
    fm_proc_info 700
  ' "$LIB" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "ps exit 1 was reported as a readable pid"
  [ ! -s "$calls" ] || fail "ps exit 1 still consulted the OS provider"
  rc=0
  FM_TEST_PS_RC=127 FM_MARKER_FILE="$calls" PATH="$fakebin:$PATH" bash -c '
    . "$0"
    fm_os_proc_triple() { printf "called\n" >> "$FM_MARKER_FILE"; return 1; }
    fm_proc_info 700
  ' "$LIB" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "a missing ps with an unreadable provider was reported as readable"
  [ -s "$calls" ] || fail "ps exit 127 did not route to the OS provider"
  pass "ps 1 stays a stop with the provider untouched; ps 127 routes to it"
}

test_ps_denial_must_be_confirmed_before_routing() {
  # A lone call's 126 is NOT the denial environment if ps itself still
  # runs: a sandbox refusing one call must never flip identity onto
  # the second provider. Only a ps that also refuses `ps -V` is the
  # blocked binary. The probe runs once per process run, not once per
  # refused pid.
  local dir fakebin calls rc log
  dir="$TMP_ROOT/denial-confirmed"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_PS_CALLS"
for a in "$@"; do
  case "$a" in -p) exit 126 ;; esac
done
exit 0
SH
  chmod +x "$fakebin/ps"
  calls="$dir/provider-calls"; : > "$calls"
  log="$dir/ps-calls"; : > "$log"
  rc=0
  FM_PS_CALLS="$log" FM_MARKER_FILE="$calls" PATH="$fakebin:$PATH" bash -c '
    . "$0"
    fm_os_proc_triple() { printf "called\n" >> "$FM_MARKER_FILE"; return 1; }
    fm_proc_info 700; first=$?
    fm_proc_info 701; second=$?
    [ "$first" -ne 0 ] && [ "$second" -ne 0 ] || exit 9
  ' "$LIB" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "ps that only refuses -p was still routed to the provider"
  [ ! -s "$calls" ] || fail "provider was consulted while ps itself runs"
  local probes
  probes=$(grep -c '^[-]V$' "$log" || true)
  [ "$probes" = 1 ] \
    || fail "the denial check ran $probes times across two refused pids, expected 1"
  pass "refused -p with a live ps -V stays a stop; the denial check is cached once"
}

test_ps_success_with_empty_comm_stays_present() {
  # ps exit 0 with no name is a REAL answer about a REAL process: a
  # live process whose comm was emptied is still a live process.
  #
  # It must not read as "the pid is gone". fm_session_lock_inspect
  # separates "gone" (stale, reclaimable) from "present but not
  # classifiable" (unknown), and collapsing the two here would report a
  # live owner as reclaimable - the take-over direction this whole
  # change exists to close. The unchanged base reports "unknown" for
  # this case, so the ps route has to agree with it.
  local dir fakebin rc
  dir="$TMP_ROOT/empty-comm"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
field=
while [ "$#" -gt 0 ]; do
  case "$1" in -o) field=$2; shift 2 ;; *) shift ;; esac
done
case "$field" in
  comm=) exit 0 ;;
  args=) printf '%s\n' 'claude --resume'; exit 0 ;;
  ppid=) printf '%s\n' 1; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/ps"
  rc=0
  PATH="$fakebin:$PATH" bash -c '
    . "$0"
    # The pid is present, so the read succeeds and reports the fields
    # ps actually gave - including an empty comm, which is reported
    # as empty rather than invented.
    fm_proc_info 700 || exit 9
    [ -z "$FM_PROC_COMM" ] || exit 8
    [ "$FM_PROC_ARGS" = "claude --resume" ] || exit 7
    [ "$FM_PROC_PPID" = "1" ] || exit 6
  ' "$LIB" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "ps rc0-with-empty-comm was not reported as a present pid (rc $rc)"

  # The lock-level consequence: a live pid ps cannot name is NOT stale.
  # "stale" means reclaimable, and a reclaimable live owner is the
  # take-over this change exists to prevent.
  local state
  state=$(mktemp -d "$TMP_ROOT/empty-comm-state.XXXXXX")
  echo 700 > "$state/.lock"
  rc=0
  PATH="$fakebin:$PATH" bash -c '
    . "$0"
    kill() { return 0; }
    fm_session_lock_inspect "$1" >/dev/null 2>&1
    printf "%s" "$FM_LOCK_INSPECT_STATE"
  ' "$LIB" "$state" > "$state/out" 2>/dev/null || rc=$?
  [ "$rc" -eq 0 ] || fail "the lock inspection failed on a present unnamed pid (rc $rc)"
  [ "$(cat "$state/out")" != "stale" ] \
    || fail "a live pid ps could not name was reported stale (reclaimable)"
  pass "ps returning no name stays a present pid, never a reclaimable stale one"
}

test_denied_ps_lock_decision_chain() {
  # The lock-level promise at lib level with a fake provider: a
  # provider-readable harness in THIS ancestry reads as our own lock,
  # and a provider-readable live harness OUTSIDE it reads as a
  # foreign live owner that must be refused, named, and never
  # reclaimed. The ps-working suites cover the same decisions against
  # real ps; this one proves the denied-ps route reaches them at all.
  local dir fakebin table state rc out
  dir="$TMP_ROOT/lock-chain"
  fakebin=$(fm_fakebin "$dir"); make_denied_ps "$fakebin"
  table="$dir/t"
  cat > "$table" <<'ROWS'
700|1|claude|claude --resume
701|1|claude|claude --other-home
1|0|launchd|/sbin/launchd
default|700|bash|bash run.sh
ROWS
  state="$dir/state"; mkdir -p "$state"
  # Ours: recorded pid 700 is a harness ancestor of this walk.
  printf '700\n' > "$state/.lock"
  FM_TEST_STATE="$state" lib_eval_denied "$fakebin" "$table" \
    'fm_session_lock_owned_by_self "$FM_TEST_STATE"' >/dev/null 2>&1 \
    || fail "denied ps: the walk did not recognize its own harness lock"
  # Foreign: 701 is a live readable harness, but not in this ancestry.
  printf '701\n' > "$state/.lock"
  rc=0
  out=$(FM_TEST_STATE="$state" lib_eval_denied "$fakebin" "$table" '
    fm_session_lock_foreign_owner_live "$FM_TEST_STATE" || exit 7
    [ "$FM_SESSION_LOCK_FOREIGN_OWNER_PID" = 701 ] || exit 6
    if fm_session_lock_owned_by_self "$FM_TEST_STATE"; then exit 5; fi
    exit 0
  ' 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "denied ps: a foreign live harness was not reported as foreign (rc $rc): $out"
  pass "denied ps: own lock is owned, foreign live harness is refused and named"
}

test_linux_provider_fixture_tree() {
  # The stat-line parser is a pure seam, so its shapes are pinned on any
  # host; the full route through FM_PROC_ROOT_OVERRIDE (the same hook
  # bin/fm-cursor-lib.sh and friends take for their fixture trees)
  # drives the real Linux branch against a saved /proc directory.
  local got
  got=$(bash -c '
    . "$0"
    fm_linux_stat_triple "700 (weird (comm) name) S 41 700 700 0 -1 4194304" "claude --resume"
  ' "$LIB") || fail "linux stat seam refused a well-formed line"
  [ "$got" = "$(printf '41\tweird (comm) name\tclaude --resume')" ] \
    || fail "linux stat seam parsed '$got', expected ppid/comm/args split at the last ) "
  if [ "$(uname -s)" = Linux ]; then
    mkdir -p "$TMP_ROOT/proc/700"
    printf '700 (claude) S 1 700 700 0 -1 4194304\n' > "$TMP_ROOT/proc/700/stat"
    printf 'claude\0--resume\0' > "$TMP_ROOT/proc/700/cmdline"
    got=$(env FM_PROC_ROOT_OVERRIDE="$TMP_ROOT/proc" \
      bash -c '. "$0"; fm_os_proc_triple 700' "$LIB") \
      || fail "fixture-tree route returned nothing"
    [ "$got" = "$(printf '1\tclaude\tclaude --resume')" ] \
      || fail "fixture-tree route printed '$got', expected ppid/comm/args"
    pass "linux route parses a fixture /proc tree through the repo's override hook"
  else
    pass "linux stat seam pinned (fixture /proc tree is Linux-only)"
  fi
}

test_denied_ps_still_finds_the_harness() {
  local dir fakebin table got
  dir="$TMP_ROOT/denied-found"
  fakebin=$(fm_fakebin "$dir"); make_denied_ps "$fakebin"
  table=$(make_table)
  got=$(lib_eval_denied "$fakebin" "$table" 'fm_harness_ancestry_pid') \
    || fail "with ps denied, the walk found no harness at all"
  [ "$got" = 700 ] \
    || fail "with ps denied, the walk resolved '$got', expected 700"
  lib_eval_denied "$fakebin" "$table" 'fm_harness_pid_alive 700' \
    || fail "with ps denied, a live harness was not recognized"
  pass "ps denied: ancestry and liveness still resolve through the OS provider"
}

test_denied_ps_without_provider_fails_closed() {
  local dir fakebin empty got
  dir="$TMP_ROOT/denied-noprovider"
  fakebin=$(fm_fakebin "$dir"); make_denied_ps "$fakebin"
  empty="$dir/empty-table"; : > "$empty"
  if got=$(lib_eval_denied "$fakebin" "$empty" 'fm_harness_ancestry_pid' 2>&1); then
    fail "with ps denied and no provider data, the walk still printed: $got"
  fi
  pass "ps denied with no provider data: the walk refuses, it never guesses"
}

test_denied_ps_rejects_a_foreign_chain() {
  local dir fakebin file got
  dir="$TMP_ROOT/denied-foreign"
  fakebin=$(fm_fakebin "$dir"); make_denied_ps "$fakebin"
  file="$dir/table"
  cat > "$file" <<'ROWS'
default|700|bash|bash run-task.sh
700|1|bash|bash outer.sh
1|0|launchd|/sbin/launchd
ROWS
  got=$(lib_eval_denied "$fakebin" "$file" 'fm_harness_ancestry_pid' 2>&1) && rc=0 || rc=1
  if [ "$rc" -eq 0 ]; then
    fail "an ancestry with no harness anywhere was still reported as one: $got"
  fi
  pass "ps denied: a chain containing no harness is still no harness"
}

test_ps_primary_never_touches_the_provider() {
  # The regression this guards: the fallback must stay dead code wherever
  # ps works, so identity behavior cannot drift for every working session.
  local dir fakebin marker table
  dir="$TMP_ROOT/ps-primary"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  700:comm=) printf '%s\n' 'claude' ;;
  700:args=) printf '%s\n' 'claude --resume' ;;
  700:ppid=) printf '%s\n' 1 ;;
  1:comm=) printf '%s\n' 'launchd' ;;
  1:args=) printf '%s\n' '/sbin/launchd' ;;
  1:ppid=) printf '%s\n' 0 ;;
  *:comm=) printf '%s\n' 'bash' ;;
  *:args=) printf '%s\n' 'bash run.sh' ;;
  *:ppid=) printf '%s\n' 700 ;;
esac
SH
  chmod +x "$fakebin/ps"
  marker="$dir/provider-was-called"; : > "$marker"
  table="$dir/t"; : > "$table"
  # Provider override records any call by writing to the marker file.
  env FM_MARKER_FILE="$marker" PATH="$fakebin:$PATH" bash -c "
    . \"\$0\"
    fm_os_proc_triple() { printf 'called\n' > \"\$FM_MARKER_FILE\"; return 1; }
    fm_harness_ancestry_pid >/dev/null || exit 3
  " "$LIB" || fail "the ps-primary walk itself failed"
  [ -s "$marker" ] && fail "with a working ps the provider was still consulted"
  pass "ps works: the fallback provider is never consulted"
}

# --- end-to-end: a real tree with a blocked ps -------------------------------

# Build a real parent/child tree: a parent process NAMED claude (a bash
# symlink), a child shell whose PATH shadows ps with a denied stub, running
# the real platform provider against real pids.
test_e2e_real_tree_with_blocked_ps() {
  # The real Darwin provider needs python3; without it there is nothing
  # real to drive, so the case skips rather than fails.
  if [ "$(uname -s)" = Darwin ] && ! command -v python3 >/dev/null 2>&1; then
    pass "e2e blocked ps: no python3 for the Darwin provider, skipped"
    return
  fi
  local dir fakebin path_with_shim named
  dir="$TMP_ROOT/e2e-blocked"
  fakebin=$(fm_fakebin "$dir"); make_denied_ps "$fakebin"

  # Real python3 stays reachable for the Darwin provider while ps is blocked:
  # the provider looks python3 up on PATH, so a shim forwards only python3
  # and ps is shadowed by the denied stub.
  #
  # The base path after the shim is the INHERITED PATH, not a hardcoded
  # /usr/bin:/bin list. The provider reads /proc through cat and tr, and a
  # host whose coreutils live outside /usr/bin (a NixOS store path, for one)
  # would otherwise lose those tools and fail the walk for a reason that has
  # nothing to do with the denied ps. fakebin stays first, so the denied ps
  # still shadows the real one; a caller that wants a fixed base sets
  # FM_TEST_BASE_PATH, the same knob the rest of the suite uses.
  path_with_shim="$fakebin"
  if command -v python3 >/dev/null 2>&1; then
    local shimdir="$dir/shim"; mkdir -p "$shimdir"
    printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$(command -v python3)" > "$shimdir/python3"
    chmod +x "$shimdir/python3"
    path_with_shim="$fakebin:$shimdir:${FM_TEST_BASE_PATH:-$PATH}"
  fi

  named="$dir/bin"; mkdir -p "$named"
  # Identity is argv[0] on both routes, which the caller sets at exec
  # time, so a symlink named claude is enough to make this process
  # "named claude" for either reader. (A COPY of /bin/bash cannot even
  # execute here: SIP kills relocated platform binaries.) Route
  # equivalence itself is pinned by test_helper_identity_matches_ps_route.
  ln -s /bin/bash "$named/claude"

  # The child resolves the anchor for its real named parent through the
  # REAL platform provider with a blocked ps. The parent stays alive until
  # the child is done, so the real chain exists for the whole walk.
  cat > "$dir/child.sh" <<CHILD
#!/usr/bin/env bash
set -u
. "\$1"
anchor=\$(fm_session_lock_anchor_pid) || { echo anchor-failed; exit 1; }
fm_proc_info "\$anchor" || { echo identity-read-failed; exit 1; }
printf '%s|%s\n' "\$anchor" "\$FM_PROC_COMM"
CHILD
  chmod +x "$dir/child.sh"

  "$named/claude" -c '
    set -u
    pidfile=$1; child=$2; path=$3; lib=$4
    printf "%s\n" "$$" > "$pidfile"
    env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID PATH="$path" \
      /bin/bash "$child" "$lib" > "$pidfile.anchor" 2>&1 &
    childpid=$!
    i=0
    while [ ! -s "$pidfile.anchor" ] && [ "$i" -lt 60 ]; do
      sleep 0.25; i=$((i + 1))
    done
    kill "$childpid" 2>/dev/null || true
    wait "$childpid" 2>/dev/null || true
  ' x "$dir/parent.pid" "$dir/child.sh" "$path_with_shim" "$LIB"

  local want got2 pid_part comm_part
  want=$(cat "$dir/parent.pid") || fail "e2e: the named parent did not record its pid"
  got2=$(cat "$dir/parent.pid.anchor") \
    || fail "e2e: no anchor output from the child"
  pid_part=${got2%%|*}
  comm_part=${got2#*|}
  [ "$pid_part" = "$want" ] \
    || fail "e2e blocked ps: child resolved '$pid_part', expected the real named-parent pid $want"
  # Identity, not just the ppid chain: the anchor's own name must
  # arrive through the provider as "claude". On macOS that fact is
  # argv[0], so an implementation reading the resolved exec path would
  # answer "bash" here and fail this assertion.
  [ "$(basename -- "$comm_part")" = claude ] \
    || fail "e2e blocked ps: anchor identity read as '$comm_part', expected a name ending in claude"
  pass "e2e blocked ps: the real platform provider identified a real harness tree, identity included"
}

test_procinfo_helper_reports_real_facts() {
  # Direct contract of bin/fm-procinfo.py on macOS (and the offsets it
  # self-verifies): for a real parent/child pair, ppid must be exact.
  [ "$(uname -s)" = Darwin ] || { pass "fm-procinfo.py: macOS-only, skipped"; return; }
  command -v python3 >/dev/null 2>&1 || { pass "fm-procinfo.py: python3 absent, skipped"; return; }
  sleep 30 &
  local child=$! out ppid comm
  out=$(python3 "$ROOT/bin/fm-procinfo.py" "$child") \
    || { kill "$child" 2>/dev/null; fail "fm-procinfo.py failed for a live pid"; }
  kill "$child" 2>/dev/null
  ppid=${out%%$'\t'*}
  comm=$(printf '%s' "$out" | cut -f2)
  [ "$ppid" = "$$" ] \
    || fail "fm-procinfo.py reported ppid '$ppid', expected $$"
  [ -n "$comm" ] \
    || fail "fm-procinfo.py reported an empty comm for a live pid"
  pass "fm-procinfo.py: ppid verified exact and identity reported for a real process"
}

test_procinfo_helper_fails_closed() {
  # The helper's promise is that an unverified read yields NOTHING, not
  # a partial guess. Case 1: a pid that is gone. Case 2: the same
  # helper with its p_pid struct offset deliberately broken - the
  # self-verification exists for exactly this, so it must produce an
  # empty refusal, never fields read from the wrong offsets.
  [ "$(uname -s)" = Darwin ] || { pass "fm-procinfo.py fail-closed: macOS-only, skipped"; return; }
  command -v python3 >/dev/null 2>&1 || { pass "fm-procinfo.py fail-closed: python3 absent, skipped"; return; }
  local out rc mutated child
  rc=0
  out=$(python3 "$ROOT/bin/fm-procinfo.py" 999999 2>/dev/null) || rc=$?
  [ "$rc" -ne 0 ] || fail "helper reported facts for pid 999999"
  [ -z "$out" ] || fail "helper printed '$out' for a nonexistent pid"
  mutated="$TMP_ROOT/procinfo-broken.py"
  sed 's/^P_PID_OFF = 40$/P_PID_OFF = 4/' "$ROOT/bin/fm-procinfo.py" > "$mutated"
  sleep 30 &
  child=$!
  rc=0
  out=$(python3 "$mutated" "$child" 2>/dev/null) || rc=$?
  kill "$child" 2>/dev/null
  [ "$rc" -ne 0 ] || fail "offset-broken helper still reported a ppid"
  [ -z "$out" ] || fail "offset-broken helper printed '$out' instead of refusing"
  pass "fm-procinfo.py: dead pid and broken offsets both produce an empty refusal"
}

test_control_bytes_match_ps_route() {
  command -v python3 >/dev/null 2>&1 || { pass "control bytes: python3 absent, skipped"; return; }
  local marker="$TMP_ROOT/control-ready" child i got expected
  python3 -c 'import os, sys
os.execv(sys.executable, [os.fsencode(sys.executable), b"-c", b"import sys,time; open(sys.argv[1], chr(119)).close(); time.sleep(40)", os.fsencode(sys.argv[1]), b"tab\tnewline\nhigh\xff"])' "$marker" &
  child=$!
  i=0
  while [ ! -f "$marker" ] && [ "$i" -lt 40 ]; do sleep 0.25; i=$((i + 1)); done
  if [ ! -f "$marker" ]; then
    kill "$child" 2>/dev/null
    wait "$child" 2>/dev/null || :
    fail "control-byte child did not become ready"
  fi
  expected=$(bash -c '. "$1"; fm_proc_info "$2" || exit; printf "%s\t%s\t%s\n" "$FM_PROC_PPID" "$FM_PROC_COMM" "$FM_PROC_ARGS"' x "$LIB" "$child") \
    || { kill "$child"; fail "ps route refused control-byte child"; }
  got=$(bash -c '. "$1"; fm_os_proc_triple "$2"' x "$LIB" "$child") \
    || { kill "$child"; fail "provider refused control-byte child"; }
  kill "$child" 2>/dev/null
  wait "$child" 2>/dev/null || :
  [ "$got" = "$expected" ] || fail "control-byte routes disagree: provider '$got', ps '$expected'"
  pass "control bytes preserve identical identity fields across routes"
}

test_helper_identity_matches_ps_route() {
  # Route equivalence, the invariant that keeps a denied-ps host from
  # handing the foreign-owner guard a different verdict than ps gives:
  # on macOS both routes read identity from argv, so a process invoked
  # under a DIFFERENT name - the case where a resolved exec path would
  # disagree - must read identically through ps and through the helper.
  [ "$(uname -s)" = Darwin ] || { pass "route equivalence: macOS-only, skipped"; return; }
  command -v python3 >/dev/null 2>&1 || { pass "route equivalence: python3 absent, skipped"; return; }
  # This case compares the two routes, so it needs a working ps as the
  # reference side; where ps itself cannot run there is nothing to
  # compare against, and the case skips.
  ps -o comm= -p $$ >/dev/null 2>&1 \
    || { pass "route equivalence: ps unavailable on this host, skipped"; return; }
  local marker="$TMP_ROOT/renamed-ready" child ps_comm ps_args got h_comm h_args i
  rm -f "$marker"
  /bin/bash -c ': > "$1"; exec -a claude-fake /bin/sleep 40' x "$marker" &
  child=$!
  # Wait for the exec to land, then require ps itself to agree before
  # judging the helper - this pins the two routes against each other.
  ps_comm=''
  i=0
  while [ ! -f "$marker" ] && [ "$i" -lt 40 ]; do sleep 0.25; i=$((i + 1)); done
  i=0
  while [ "$i" -lt 40 ]; do
    ps_comm=$(ps -o comm= -p "$child" 2>/dev/null | tr -d ' ')
    [ "$ps_comm" = "claude-fake" ] && break
    sleep 0.25; i=$((i + 1))
  done
  if [ "$ps_comm" != "claude-fake" ]; then
    kill "$child" 2>/dev/null
    fail "renamed child never settled as 'claude-fake' under ps (got '$ps_comm')"
  fi
  ps_args=$(ps -o args= -p "$child" 2>/dev/null)
  got=$(python3 "$ROOT/bin/fm-procinfo.py" "$child") \
    || { kill "$child" 2>/dev/null; fail "helper refused the renamed child ps just verified"; }
  kill "$child" 2>/dev/null
  h_comm=$(printf '%s' "$got" | cut -f2)
  h_args=$(printf '%s' "$got" | cut -f3-)
  [ "$h_comm" = "$ps_comm" ] \
    || fail "routes disagree on comm: helper '$h_comm', ps '$ps_comm'"
  [ "$h_args" = "$ps_args" ] \
    || fail "routes disagree on args: helper '$h_args', ps '$ps_args'"
  pass "renamed process: the ps route and the ps-free route report one identity"
}

test_procinfo_helper_survives_empty_argv_element() {
  command -v python3 >/dev/null 2>&1 \
    || { pass "empty argv element: python3 absent, skipped"; return; }
  local shape marker child i got expected args suffix
  for shape in one two middle space; do
    marker="$TMP_ROOT/empty-$shape-ready"
    python3 -c 'import os, sys
extra = {"one": ["--resume", ""], "two": ["--resume", "", ""], "middle": ["aa", "", "bb"], "space": ["tail "]}[sys.argv[2]]
os.execv(sys.executable, [sys.executable, "-c", "import sys,time; open(sys.argv[1], chr(119)).close(); time.sleep(40)", sys.argv[1]] + extra)' "$marker" "$shape" &
    child=$!
    i=0
    while [ ! -f "$marker" ] && [ "$i" -lt 40 ]; do sleep 0.25; i=$((i + 1)); done
    if [ ! -f "$marker" ]; then
      kill "$child" 2>/dev/null
      wait "$child" 2>/dev/null || :
      fail "empty-element child did not become ready"
    fi
    expected=$(bash -c '. "$1"; fm_proc_info "$2" || exit; printf "%s\t%s\t%s\n" "$FM_PROC_PPID" "$FM_PROC_COMM" "$FM_PROC_ARGS"' x "$LIB" "$child") \
      || { kill "$child"; fail "ps refused empty-element child"; }
    got=$(bash -c '. "$1"; fm_os_proc_triple "$2"' x "$LIB" "$child") \
      || { kill "$child"; fail "provider refused empty-element child"; }
    kill "$child" 2>/dev/null
    wait "$child" 2>/dev/null || :
    [ "$got" = "$expected" ] || fail "$shape argv routes disagree: provider '$got', ps '$expected'"
    args=${got##*$'\t'}
    case "$shape" in
      one|two) suffix='--resume' ;;
      middle) suffix='aa  bb' ;;
      space) suffix='tail ' ;;
    esac
    case "$args" in
      *"$marker $suffix") ;;
      *) fail "$shape argv lost element spacing: '$args'" ;;
    esac
  done
  pass "trailing empty argv elements are dropped; interior empties and argument spaces survive"
}

test_unreadable_owner_refuses_acquisition() {
  [ "$(uname -s)" = Linux ] || { pass "unreadable owner acquisition: Linux fixture only, skipped"; return; }
  local dir fakebin real_ps owner rc
  dir="$TMP_ROOT/unreadable-acquisition"
  fakebin=$(fm_fakebin "$dir")
  real_ps=$(command -v ps)
  owner=$$
  mkdir -p "$dir/state" "$dir/proc" "$dir/named"
  printf '%s\n' "$owner" > "$dir/state/.lock"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" -V "*|*" -p $FM_TEST_OWNER "*) exit 126 ;;
esac
exec "$FM_TEST_REAL_PS" "$@"
SH
  chmod +x "$fakebin/ps"
  ln -s "$(command -v bash)" "$dir/named/claude"
  rc=0
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_TEST_OWNER="$owner" FM_TEST_REAL_PS="$real_ps" \
    FM_PROC_ROOT_OVERRIDE="$dir/proc" FM_STATE_OVERRIDE="$dir/state" \
    PATH="$fakebin:$PATH" "$dir/named/claude" -c 'bash "$1/bin/fm-lock.sh"; rc=$?; exit "$rc"' _ "$ROOT" \
    > "$dir/out" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "acquisition took over an unreadable live owner"
  [ "$(cat "$dir/state/.lock")" = "$owner" ] || fail "acquisition replaced the unreadable owner"
  grep -q 'another live firstmate session' "$dir/out" || fail "acquisition did not refuse the owner"
  pass "acquisition refuses a live owner with unreadable identity"
}

test_partial_identity_reads_refuse() {
  local dir fakebin got
  dir="$TMP_ROOT/partial-identity"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$2" in
  comm=) echo node ;;
  args=) [ "$FM_TEST_FAILED_FIELD" != args ] || exit 1 ;;
  ppid=) [ "$FM_TEST_FAILED_FIELD" != ppid ] || exit 1; echo 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
  # The identity the matcher reads is comm and args. A failed args read is
  # a partial identity: a live harness whose arguments could not be read
  # must not be reduced to a bare interpreter name, so the read is
  # unreadable and the lock is not reclaimable.
  PATH="$fakebin:$PATH" FM_TEST_FAILED_FIELD=args bash -c '
    . "$1"
    kill() { return 0; }
    fm_session_lock_pid_blocks_reclaim 700 || exit 1
    [ "$FM_SESSION_LOCK_PID_VERDICT" = unreadable ]
  ' _ "$LIB" || fail "failed ps args read permitted reclaim"
  # The ppid is a walk input, not an identity field: a ppid that cannot be
  # read only ends the ancestry walk one hop early, which is the
  # conservative direction. The base read it the same tolerant way, and
  # the grok and kimi harness suites pin that - their stubbed ps answers
  # comm= and args= and refuses every other question.
  PATH="$fakebin:$PATH" FM_TEST_FAILED_FIELD=ppid bash -c '
    . "$1"
    kill() { return 0; }
    fm_session_lock_pid_blocks_reclaim 700 && exit 1
    [ "$FM_SESSION_LOCK_PID_VERDICT" = readable ]
    [ -z "$FM_PROC_PPID" ]
  ' _ "$LIB" || fail "a failed ps ppid read was treated as an identity failure"
  PATH="$fakebin:$PATH" FM_TEST_FAILED_FIELD=none bash -c '
    . "$1"
    fm_proc_info 700 && [ -z "$FM_PROC_ARGS" ]
  ' _ "$LIB" || fail "successfully empty ps args were refused"
  if [ "$(uname -s)" = Linux ]; then
    mkdir -p "$dir/proc/700"
    printf '700 (node) S 1 700 700 0 -1 4194304\n' > "$dir/proc/700/stat"
    make_denied_ps "$fakebin"
    PATH="$fakebin:$PATH" FM_PROC_ROOT_OVERRIDE="$dir/proc" bash -c '
      . "$1"
      kill() { return 0; }
      fm_session_lock_pid_blocks_reclaim 700 || exit 1
      [ "$FM_SESSION_LOCK_PID_VERDICT" = unreadable ]
    ' _ "$LIB" || fail "missing cmdline permitted reclaim"
    : > "$dir/proc/700/cmdline"
    got=$(FM_PROC_ROOT_OVERRIDE="$dir/proc" bash -c '. "$1"; fm_os_proc_triple 700' _ "$LIB") \
      || fail "successfully empty cmdline was refused"
    [ "$got" = "$(printf '1\tnode\t')" ] || fail "empty cmdline changed identity fields"
  fi
  pass "partial identity reads block reclaim; successfully empty args remain readable"
}

test_nonpid_records_allow_acquisition() {
  local dir record
  dir="$TMP_ROOT/nonpid-acquisition"
  mkdir -p "$dir/named" "$dir/state"
  ln -s "$(command -v bash)" "$dir/named/claude"
  for record in '' '   ' 'not-a-pid'; do
    printf '%s\n' "$record" > "$dir/state/.lock"
    env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID FM_STATE_OVERRIDE="$dir/state" \
      "$dir/named/claude" -c 'bash "$1/bin/fm-lock.sh"; rc=$?; exit "$rc"' _ "$ROOT" \
      > "$dir/out" 2>&1 || fail "non-pid record refused acquisition: $record"
    [ "$(cat "$dir/state/.lock")" != "$record" ] || fail "non-pid record was not replaced"
  done
  pass "empty, whitespace and non-numeric lock records allow acquisition"
}

test_unreadable_verdict_returns_success() {
  local dir fakebin table got
  dir="$TMP_ROOT/unreadable-verdict"
  fakebin=$(fm_fakebin "$dir"); make_denied_ps "$fakebin"
  table="$dir/t"
  : > "$table"
  got=$(FM_TEST_KILL_RC=0 lib_eval_denied "$fakebin" "$table" '
    set -e
    fm_session_lock_pid_verdict 700
    printf "%s|%s\n" "$?" "$FM_SESSION_LOCK_PID_VERDICT"
  ') || fail "unreadable verdict aborted an errexit caller"
  [ "$got" = '0|unreadable' ] || fail "unreadable verdict returned unexpected status or value: $got"
  pass "live owner with unreadable identity returns a successful verdict"
}

test_unreadable_verdict_returns_success
test_partial_identity_reads_refuse
test_nonpid_records_allow_acquisition

test_unreadable_owner_refuses_acquisition
test_denied_route_fields_parse_exactly
test_provider_shape_violations_rejected
test_provider_empty_field_is_a_present_pid
test_ps_failure_statuses_route_correctly
test_ps_denial_must_be_confirmed_before_routing
test_ps_success_with_empty_comm_stays_present
test_denied_ps_lock_decision_chain
test_linux_provider_fixture_tree
test_denied_ps_still_finds_the_harness
test_denied_ps_without_provider_fails_closed
test_denied_ps_rejects_a_foreign_chain
test_ps_primary_never_touches_the_provider
test_e2e_real_tree_with_blocked_ps
test_procinfo_helper_reports_real_facts
test_procinfo_helper_fails_closed
test_helper_identity_matches_ps_route
test_control_bytes_match_ps_route
test_procinfo_helper_survives_empty_argv_element

echo "ALL PASS"
