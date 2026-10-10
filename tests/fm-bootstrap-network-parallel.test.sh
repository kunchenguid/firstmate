#!/usr/bin/env bash
# Concurrent deferred-network secondmate probes must keep every per-mate
# diagnostic complete, attributed, and fail-closed.
#
# The session-start network stage used to walk remote secondmates one after
# another. The public contract that must survive concurrency is not a particular
# worker scheduler: it is that each mate still emits its own SECONDMATE_LIVENESS
# / SECONDMATE_SYNC line, that those lines cannot splice into each other, and
# that a dirty or unreachable mate still refuses rather than proceeding. This
# suite drives bin/fm-bootstrap.sh's network-only phase through FM_SSH_BIN, so
# it exercises the same remote probe path a real session start uses.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-bootstrap-network-parallel)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
export FM_BACKEND_CMUX_BUNDLE_BIN="$TMP_ROOT/no-bundled-cmux"
unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH \
  CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_SOCKET_PATH CMUX_TAB_ID CMUX_PANEL_ID \
  2>/dev/null || true

command -v python3 >/dev/null 2>&1 \
  || fail "python3 is required to decode the fm-on.sh argv payload"

REAL_GIT=$(command -v git) || fail "git is required"
REAL_MKTEMP=$(command -v mktemp) || fail "mktemp is required"
fm_git_identity fmtest fmtest@example.invalid

[ -z "${FM_TEST_EVIDENCE_FILE:-}" ] || : > "$FM_TEST_EVIDENCE_FILE"

write_remote_registry_line() { # <file> <id> <host> <root> <home>
  printf -- '- %s - %s delivery (host: %s; root: %s; home: %s; scope: test work; projects: alpha; added 2026-08-02)\n' \
    "$2" "$2" "$3" "$4" "$5" >> "$1"
}

install_fake_ssh() {
  local fakebin=$1
  cat > "$fakebin/fake-ssh" <<'SH'
#!/usr/bin/env bash
set -eu
log=${FM_FAKE_SSH_LOG:?}
sleep_s=${FM_FAKE_SSH_SLEEP:-0.4}
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    --) shift; break ;;
    *) exit 90 ;;
  esac
done
host=${1:-}
entry=${2:-}
shift 2 || true
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
argv_b64=${4:-}
cmd=$(python3 -c 'import sys, base64
raw = base64.b64decode(sys.argv[1])
parts = [p.decode() for p in raw.split(b"\0") if p]
print(parts[0] if parts else "")
print(parts[1] if len(parts) > 1 else "")
print(parts[2] if len(parts) > 2 else "")
' "$argv_b64")
command_name=$(printf '%s\n' "$cmd" | sed -n '1p')
subcommand=$(printf '%s\n' "$cmd" | sed -n '2p')
item_rel=$(printf '%s\n' "$cmd" | sed -n '3p')
slow=0
case "$command_name" in
  fm-remote-doctor.sh) slow=1 ;;
  fm-remote-secondmate-control.sh)
    case "$subcommand" in state|sync) slow=1 ;; esac
    ;;
esac
if [ "$slow" -eq 1 ]; then
  printf 'START %s %s %s\n' "$host" "$command_name" "$subcommand" >> "$log"
  # Do not let scheduler latency turn the concurrency assertion into a race
  # between equal sleeps. If the fetch worker was launched concurrently, give
  # it a bounded opportunity to publish its START record.
  waited=0
  while ! grep -q '^START fleet-fetch ' "$log" && [ "$waited" -lt 500 ]; do
    sleep 0.01
    waited=$((waited + 1))
  done
  sleep "$sleep_s"
  printf 'END %s %s %s\n' "$host" "$command_name" "$subcommand" >> "$log"
else
  printf 'QUICK %s %s %s\n' "$host" "$command_name" "$subcommand" >> "$log"
fi
case "$host" in
  "${FM_FAKE_SSH_UNREACHABLE_HOST:-host-bravo}")
    exit 255
    ;;
esac
case "$command_name" in
  fm-remote-doctor.sh)
    exit 0
    ;;
  fm-remote-secondmate-control.sh)
    case "$subcommand" in
      state)
        printf 'alive\n'
        exit 0
        ;;
      route)
        printf 'backend=herdr\n'
        exit 0
        ;;
      sync)
        case "$host" in
          "${FM_FAKE_SSH_FAIL_HOST:-host-alpha}")
            printf 'synthetic tracked-file sync refusal for %s\n' "$host"
            exit 1
            ;;
          "${FM_FAKE_SSH_DIRTY_HOST:-host-charlie}")
            printf 'remote secondmate checkout is dirty; sync skipped\n'
            exit 1
            ;;
        esac
        printf 'current: test\n'
        exit 0
        ;;
    esac
    exit 0
    ;;
  fm-remote-inherit.sh)
    case "$subcommand" in
      put) printf 'unchanged: %s\n' "$item_rel" ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/fake-ssh"
}

install_slow_git() {
  local fakebin=$1 real_git=$2 log=$3
  cat > "$fakebin/git" <<SH
#!/usr/bin/env bash
set -eu
slow=0
for arg in "\$@"; do
  if [ "\$arg" = fetch ]; then
    slow=1
    break
  fi
done
if [ "\$slow" -eq 1 ]; then
  printf 'START fleet-fetch git fetch\n' >> '$log'
  waited=0
  while ! grep -q '^START host-.* fm-remote-doctor.sh ' '$log' && [ "\$waited" -lt 500 ]; do
    sleep 0.01
    waited=\$((waited + 1))
  done
  sleep "\${FM_FAKE_GIT_FETCH_SLEEP:-0.4}"
  printf 'END fleet-fetch git fetch\n' >> '$log'
fi
exec '$real_git' "\$@"
SH
  chmod +x "$fakebin/git"
}

starts_before_first_end() { # <log> <pattern>
  awk -v pat="$2" '
    $0 ~ pat && $1 == "START" { starts++ }
    $0 ~ pat && $1 == "END" {
      print starts + 0
      found = 1
      exit
    }
    END { if (!found) print starts + 0 }
  ' "$1"
}

test_remote_probe_scheduling_keeps_per_mate_lines() { # <parallel|fallback>
  local mode=$1
  local dir home primary fakebin log out n doctor_overlap liveness_starts fetch_starts
  local alpha_root alpha_home bravo_root bravo_home charlie_root charlie_home
  dir="$TMP_ROOT/parallel-lines-$mode"
  home="$dir/home"
  primary="$dir/primary"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" "$primary"
  git init -q -b main "$primary"
  cp -R "$ROOT/bin" "$primary/bin"
  printf 'test primary\n' > "$primary/AGENTS.md"
  git -C "$primary" add AGENTS.md bin
  git -C "$primary" commit -qm 'seed primary default branch'
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" gh treehouse tmux node
  log="$dir/probe.log"
  : > "$log"
  install_fake_ssh "$fakebin"
  install_slow_git "$fakebin" "$REAL_GIT" "$log"
  if [ "$mode" = fallback ]; then
    cat > "$fakebin/mktemp" <<SH
#!/usr/bin/env bash
case "\$*" in *fm-bootstrap-par.XXXXXX*) exit 1 ;; esac
exec '$REAL_MKTEMP' "\$@"
SH
    chmod +x "$fakebin/mktemp"
  fi

  alpha_root="$dir/remote/alpha/root"
  alpha_home="$dir/remote/alpha/home"
  bravo_root="$dir/remote/bravo/root"
  bravo_home="$dir/remote/bravo/home"
  charlie_root="$dir/remote/charlie/root"
  charlie_home="$dir/remote/charlie/home"
  mkdir -p "$alpha_root" "$alpha_home" "$bravo_root" "$bravo_home" "$charlie_root" "$charlie_home"

  : > "$home/data/secondmates.md"
  write_remote_registry_line "$home/data/secondmates.md" alpha host-alpha "$alpha_root" "$alpha_home"
  write_remote_registry_line "$home/data/secondmates.md" bravo host-bravo "$bravo_root" "$bravo_home"
  write_remote_registry_line "$home/data/secondmates.md" charlie host-charlie "$charlie_root" "$charlie_home"

  fm_write_secondmate_meta "$home/state/alpha.meta" "$alpha_home"
  printf 'remote_host=host-alpha\n' >> "$home/state/alpha.meta"
  fm_write_secondmate_meta "$home/state/bravo.meta" "$bravo_home"
  printf 'remote_host=host-bravo\n' >> "$home/state/bravo.meta"
  fm_write_secondmate_meta "$home/state/charlie.meta" "$charlie_home"
  printf 'remote_host=host-charlie\n' >> "$home/state/charlie.meta"

  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$dir/alpha.origin.git"

  out=$(
    PATH="$fakebin:$BASE_PATH" \
    FM_HOME="$home" \
    FM_ROOT_OVERRIDE="$primary" \
    FM_BOOTSTRAP_NETWORK=only \
    FM_SSH_BIN="$fakebin/fake-ssh" \
    FM_FAKE_SSH_LOG="$log" \
    FM_FAKE_SSH_SLEEP=0.4 \
    FM_FAKE_SSH_UNREACHABLE_HOST=host-bravo \
    FM_FAKE_SSH_FAIL_HOST=host-alpha \
    FM_FAKE_SSH_DIRTY_HOST=host-charlie \
    FM_FAKE_GIT_FETCH_SLEEP=0.4 \
    FM_INHERITABLE_CONFIG='' \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1
  )

  assert_contains "$out" \
    "SECONDMATE_LIVENESS: secondmate bravo: skipped: remote host unavailable or endpoint state unknown; route preserved on host-bravo" \
    "an unreachable mate must fail closed with its own liveness line"
  assert_contains "$out" \
    "SECONDMATE_SYNC: secondmate bravo: skipped:" \
    "an unreachable mate must also fail closed on convergence rather than disappearing"
  assert_contains "$out" \
    "SECONDMATE_SYNC: secondmate charlie: skipped: remote tracked-file sync failed on host-charlie:" \
    "a dirty remote mate must fail closed with its own sync line"
  assert_contains "$out" "dirty" \
    "the dirty mate's skip line must still name dirtiness"

  n=$(printf '%s\n' "$out" | grep -c 'SECONDMATE_LIVENESS: secondmate bravo:' || true)
  [ "$n" -eq 1 ] || fail "bravo liveness line was lost or duplicated (count=$n)"$'\n'"$out"
  n=$(printf '%s\n' "$out" | grep -c 'SECONDMATE_SYNC: secondmate charlie:' || true)
  [ "$n" -eq 1 ] || fail "charlie sync line was lost or duplicated (count=$n)"$'\n'"$out"
  n=$(printf '%s\n' "$out" | sed -n 's/^SECONDMATE_SYNC: secondmate \([^:]*\):.*/\1/p' | tr '\n' ' ')
  [ "$n" = "alpha bravo bravo charlie " ] \
    || fail "sync diagnostics were lost, duplicated, or replayed outside spawn order: $n"$'\n'"$out"

  assert_not_contains "$out" \
    "SECONDMATE_LIVENESS: secondmate alpha: skipped: remote host unavailable or endpoint state unknown" \
    "a reachable mate must not inherit the unreachable mate's liveness skip"
  assert_contains "$out" \
    "SECONDMATE_SYNC: secondmate alpha: skipped: remote tracked-file sync failed on host-alpha: synthetic tracked-file sync refusal for host-alpha" \
    "the first worker's diagnostic must retain its own host and complete message"
  assert_not_contains "$out" \
    "SECONDMATE_SYNC: secondmate alpha: skipped: remote tracked-file sync failed on host-alpha: remote secondmate checkout is dirty" \
    "the first worker must not inherit the dirty mate's reason"

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      SECONDMATE_LIVENESS:\ secondmate\ [A-Za-z0-9._-]*:*|SECONDMATE_SYNC:\ secondmate\ [A-Za-z0-9._-]*:*) ;;
      *) fail "a per-mate line was interleave-corrupted: $line" ;;
    esac
    n=0
    case "$line" in *" secondmate alpha:"*) n=$((n + 1)) ;; esac
    case "$line" in *" secondmate bravo:"*) n=$((n + 1)) ;; esac
    case "$line" in *" secondmate charlie:"*) n=$((n + 1)) ;; esac
    [ "$n" -le 1 ] || fail "a per-mate line named more than one mate: $line"
  done <<EOF
$(printf '%s\n' "$out" | grep '^SECONDMATE_' || true)
EOF

  doctor_overlap=$(starts_before_first_end "$log" 'fm-remote-doctor.sh')
  if [ "$mode" = parallel ]; then
    [ "$doctor_overlap" -ge 2 ] \
      || fail "remote liveness probes did not overlap (starts before first doctor end=$doctor_overlap)"$'\n'"$(cat "$log")"
  else
    [ "$doctor_overlap" -eq 1 ] \
      || fail "mktemp failure did not select sequential liveness fallback (starts before first doctor end=$doctor_overlap)"$'\n'"$(cat "$log")"
  fi

  liveness_starts=$(grep -c '^START .* fm-remote-secondmate-control.sh state$' "$log" || true)
  [ "$liveness_starts" -ge 2 ] \
    || fail "expected concurrent remote state probes, got $liveness_starts"$'\n'"$(cat "$log")"

  fetch_starts=$(grep -c '^START fleet-fetch ' "$log" || true)
  [ "$fetch_starts" -ge 1 ] \
    || fail "clone refresh did not start a fetch to overlap with secondmate probes"$'\n'"$(cat "$log")"
  awk '
    /^START fleet-fetch / { fleet = 1; if (remote) overlap = 1; next }
    /^END fleet-fetch / { fleet = 0; next }
    /^START host-/ { remote++; if (fleet) overlap = 1; next }
    /^END host-/ { remote-- }
    END { exit !overlap }
  ' "$log" || fail "clone refresh did not overlap the secondmate sweeps"$'\n'"$(cat "$log")"

  awk '
    /END .* fm-remote-secondmate-control.sh state$/ { last_liveness = NR }
    /START .* fm-remote-secondmate-control.sh sync$/ && !first_sync { first_sync = NR }
    END { exit !(last_liveness && first_sync && last_liveness < first_sync) }
  ' "$log" || fail "convergence began before all liveness probes finished"$'\n'"$(cat "$log")"

  if [ -n "${FM_TEST_EVIDENCE_FILE:-}" ]; then
    {
      printf '=== %s bootstrap network output ===\n%s\n' "$mode" "$out"
      printf '=== %s remote operation timeline ===\n' "$mode"
      cat "$log"
    } >> "$FM_TEST_EVIDENCE_FILE"
  fi

  pass "bootstrap network ($mode): per-mate output stays intact, fail-closed, and correctly sequenced"
}

test_remote_inheritance_failure_names_its_own_error_not_an_unchanged_item() {
  local dir home primary fakebin log out sm_root sm_home line
  dir="$TMP_ROOT/inherit-failure"
  home="$dir/home"
  primary="$dir/primary"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" "$primary"
  git init -q -b main "$primary"
  cp -R "$ROOT/bin" "$primary/bin"
  printf 'test primary\n' > "$primary/AGENTS.md"
  git -C "$primary" add AGENTS.md bin
  git -C "$primary" commit -qm 'seed primary default branch'
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" gh treehouse tmux node
  log="$dir/probe.log"
  : > "$log"
  install_fake_ssh "$fakebin"

  sm_root="$dir/remote/sm/root"
  sm_home="$dir/remote/sm/home"
  mkdir -p "$sm_root" "$sm_home"

  : > "$home/data/secondmates.md"
  write_remote_registry_line "$home/data/secondmates.md" sm host-sm "$sm_root" "$sm_home"
  fm_write_secondmate_meta "$home/state/sm.meta" "$sm_home"
  printf 'remote_host=host-sm\n' >> "$home/state/sm.meta"

  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$dir/alpha.origin.git"

  printf '{}\n' > "$home/config/crew-dispatch.json"
  printf 'codex\n' > "$home/config/crew-harness"
  # Header omits "must not be edited there" so the local check fails before
  # any ssh call for this item, after the two config items above already
  # reported "unchanged:" from the (faked) remote.
  cat > "$home/data/captain-shared.md" <<'EOF'
# Shared captain preferences

This file is main-authoritative in the main firstmate home.
In secondmate homes it is read-only in secondmate homes.
Route new captain-preference discoveries to the main firstmate through marked status or a document pointer.
EOF

  out=$(
    PATH="$fakebin:$BASE_PATH" \
    FM_HOME="$home" \
    FM_ROOT_OVERRIDE="$primary" \
    FM_BOOTSTRAP_NETWORK=only \
    FM_SSH_BIN="$fakebin/fake-ssh" \
    FM_FAKE_SSH_LOG="$log" \
    FM_FAKE_SSH_SLEEP=0 \
    FM_FAKE_GIT_FETCH_SLEEP=0 \
    FM_INHERITABLE_CONFIG='crew-dispatch.json crew-harness' \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1
  )

  line=$(printf '%s\n' "$out" | grep '^SECONDMATE_SYNC: secondmate sm: skipped: remote inheritance failed on host-sm:' || true)
  [ -n "$line" ] || fail "expected a remote inheritance failure line: $out"
  case "$line" in
    *"shared captain preferences"*) ;;
    *) fail "the failure reason should name the shared captain header problem, got: $line" ;;
  esac
  case "$line" in
    *"unchanged:"*) fail "the failure reason must not report an earlier unchanged item, got: $line" ;;
  esac

  if [ -n "${FM_TEST_EVIDENCE_FILE:-}" ]; then
    printf '=== inherit-failure bootstrap output ===\n%s\n' "$out" >> "$FM_TEST_EVIDENCE_FILE"
  fi

  pass "a remote inheritance failure reports its own error line, not an earlier unchanged item"
}

# install_item_ssh <fakebin>: a fake ssh for the convergence path. Every
# remote command logs START and END lines; an inheritance item sleeps
# FM_FAKE_ITEM_SLEEP and answers "unchanged: <item>", or fails when it is
# FM_FAKE_ITEM_FAIL. A tracked-file sync on FM_FAKE_SYNC_HANG_HOST never
# answers within the test's budget.
install_item_ssh() {
  local fakebin=$1
  cat > "$fakebin/fake-ssh" <<'SH'
#!/usr/bin/env bash
set -u
log=${FM_FAKE_SSH_LOG:?}
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    --) shift; break ;;
    *) exit 90 ;;
  esac
done
host=${1:-}
shift 2 || true
argv_b64=${4:-}
cmd=$(python3 -c 'import sys, base64
parts = [p.decode() for p in base64.b64decode(sys.argv[1]).split(b"\0") if p]
print("\n".join((parts + ["", "", ""])[:3]))' "$argv_b64")
command_name=$(printf '%s\n' "$cmd" | sed -n '1p')
subcommand=$(printf '%s\n' "$cmd" | sed -n '2p')
item_rel=$(printf '%s\n' "$cmd" | sed -n '3p')
cat > /dev/null
printf 'START %s %s %s %s\n' "$host" "$command_name" "$subcommand" "$item_rel" >> "$log"
case "$command_name:$subcommand" in
  fm-remote-secondmate-control.sh:sync)
    if [ "$host" = "${FM_FAKE_SYNC_HANG_HOST:-none}" ]; then
      sleep 120
    fi
    printf 'END %s %s %s\n' "$host" "$command_name" "$subcommand" >> "$log"
    printf 'current: test\n'
    exit 0
    ;;
  fm-remote-secondmate-control.sh:state) printf 'END %s\n' "$host" >> "$log"; printf 'alive\n'; exit 0 ;;
  fm-remote-secondmate-control.sh:route) printf 'END %s\n' "$host" >> "$log"; printf 'backend=herdr\n'; exit 0 ;;
  fm-remote-inherit.sh:*)
    # The failing item answers at once, so it settles before any sibling.
    if [ "$item_rel" = "${FM_FAKE_ITEM_FAIL:-none}" ]; then
      printf 'END %s %s %s %s\n' "$host" "$command_name" "$subcommand" "$item_rel" >> "$log"
      printf 'error: synthetic refusal of %s\n' "$item_rel" >&2
      exit 1
    fi
    sleep "${FM_FAKE_ITEM_SLEEP:-0}"
    printf 'END %s %s %s %s\n' "$host" "$command_name" "$subcommand" "$item_rel" >> "$log"
    if [ "$item_rel" = "${FM_FAKE_ITEM_PUSHED:-none}" ]; then
      printf 'pushed: %s\n' "$item_rel"
      exit 0
    fi
    printf 'unchanged: %s\n' "$item_rel"
    exit 0
    ;;
esac
printf 'END %s %s %s\n' "$host" "$command_name" "$subcommand" >> "$log"
exit 0
SH
  chmod +x "$fakebin/fake-ssh"
}

# convergence_fixture <dir> <mate:host>...: a primary checkout and a home whose
# registry records each mate as a remote route. Sets CF_HOME, CF_PRIMARY,
# CF_FAKEBIN, and CF_LOG.
convergence_fixture() {
  local dir=$1 spec id host
  shift
  CF_HOME="$dir/home"
  CF_PRIMARY="$dir/primary"
  mkdir -p "$CF_HOME/state" "$CF_HOME/data" "$CF_HOME/config" "$CF_HOME/projects" "$CF_PRIMARY"
  git init -q -b main "$CF_PRIMARY"
  cp -R "$ROOT/bin" "$CF_PRIMARY/bin"
  printf 'test primary\n' > "$CF_PRIMARY/AGENTS.md"
  git -C "$CF_PRIMARY" add AGENTS.md bin
  git -C "$CF_PRIMARY" commit -qm 'seed primary default branch'
  CF_FAKEBIN=$(fm_fakebin "$dir")
  fm_fake_exit0 "$CF_FAKEBIN" gh treehouse tmux node
  CF_LOG="$dir/remote.log"
  : > "$CF_LOG"
  install_item_ssh "$CF_FAKEBIN"
  : > "$CF_HOME/data/secondmates.md"
  for spec in "$@"; do
    id=${spec%%:*}
    host=${spec#*:}
    mkdir -p "$dir/remote/$id/root" "$dir/remote/$id/home"
    write_remote_registry_line "$CF_HOME/data/secondmates.md" "$id" "$host" "$dir/remote/$id/root" "$dir/remote/$id/home"
    fm_write_secondmate_meta "$CF_HOME/state/$id.meta" "$dir/remote/$id/home"
    printf 'remote_host=%s\n' "$host" >> "$CF_HOME/state/$id.meta"
  done
}

run_inherit_push() {  # <id> <generation> -> stdout+stderr; status of the push
  PATH="$CF_FAKEBIN:$BASE_PATH" \
    FM_HOME="$CF_HOME" \
    FM_ROOT_OVERRIDE="$CF_PRIMARY" \
    FM_SSH_BIN="$CF_FAKEBIN/fake-ssh" \
    FM_FAKE_SSH_LOG="$CF_LOG" \
    FM_INHERITABLE_CONFIG='item-a item-b item-c item-d item-e item-f' \
    "$ROOT/bin/fm-remote-inherit-push.sh" "$@" 2>&1
}

max_inherit_overlap() {  # <log>: the most inheritance items in flight at once
  awk '
    $1 == "START" && $3 == "fm-remote-inherit.sh" { n++; if (n > max) max = n }
    $1 == "END" && $3 == "fm-remote-inherit.sh" { n-- }
    END { print max + 0 }
  ' "$1"
}

test_inherit_push_overlaps_items_and_replays_in_order() {
  local out rc order
  convergence_fixture "$TMP_ROOT/push-overlap" sm:host-sm
  out=$(FM_FAKE_ITEM_SLEEP=0.4 run_inherit_push sm 1); rc=$?
  expect_code 0 "$rc" "a clean push should succeed: $out"
  [ "$(max_inherit_overlap "$CF_LOG")" -ge 2 ] \
    || fail "inheritance items did not overlap"$'\n'"$(cat "$CF_LOG")"
  [ "$(max_inherit_overlap "$CF_LOG")" -le 4 ] \
    || fail "more than the default four inheritance items were in flight"$'\n'"$(cat "$CF_LOG")"
  order=$(printf '%s\n' "$out" | sed -n 's/^unchanged: //p' | tr '\n' ' ')
  [ "$order" = "config/item-a config/item-b config/item-c config/item-d config/item-e config/item-f data/captain-shared.md " ] \
    || fail "the push output was not replayed in allowlist order: $order"$'\n'"$out"

  : > "$CF_LOG"
  out=$(FM_FAKE_ITEM_SLEEP=0.2 FM_REMOTE_INHERIT_PUSH_JOBS=1 run_inherit_push sm 2); rc=$?
  expect_code 0 "$rc" "a one-at-a-time push should succeed: $out"
  [ "$(max_inherit_overlap "$CF_LOG")" -eq 1 ] \
    || fail "FM_REMOTE_INHERIT_PUSH_JOBS=1 must send one item at a time"$'\n'"$(cat "$CF_LOG")"
  pass "remote inheritance push: items overlap up to the bound and replay in allowlist order"
}

test_inherit_push_failure_stops_new_sends() {
  local out rc
  convergence_fixture "$TMP_ROOT/push-failure" sm:host-sm
  out=$(FM_FAKE_ITEM_FAIL=config/item-c FM_REMOTE_INHERIT_PUSH_JOBS=1 run_inherit_push sm 1); rc=$?
  [ "$rc" -ne 0 ] || fail "a failed item must fail the push: $out"
  assert_contains "$out" "error: synthetic refusal of config/item-c" "the failed item's own error must be reported"
  assert_contains "$out" "unchanged: config/item-b" "items sent before the failure are still reported"
  if grep -q 'START .* config/item-d' "$CF_LOG"; then
    fail "an item after the failed one was still sent"$'\n'"$(cat "$CF_LOG")"
  fi
  assert_not_contains "$out" "config/item-d" "no item after the failure may be reported as sent"

  : > "$CF_LOG"
  out=$(FM_FAKE_ITEM_FAIL=config/item-a FM_FAKE_ITEM_SLEEP=2 run_inherit_push sm 2); rc=$?
  [ "$rc" -ne 0 ] || fail "a failed first item must fail a concurrent push: $out"
  if grep -q 'START .* data/captain-shared.md' "$CF_LOG"; then
    fail "a concurrent push kept starting items after the first item failed"$'\n'"$(cat "$CF_LOG")"
  fi
  pass "remote inheritance push: a failed item fails the push and no later item is started"
}

test_inherit_push_local_refusal_sends_nothing() {
  local out rc
  convergence_fixture "$TMP_ROOT/push-refusal" sm:host-sm
  # item-a is ordinary and comes first; only item-e is unsafe.
  printf 'local\n' > "$CF_HOME/config/item-a"
  printf 'local\n' > "$CF_HOME/config/item-e"
  ln "$CF_HOME/config/item-e" "$TMP_ROOT/push-refusal/item-e.extra-link"
  out=$(run_inherit_push sm 1); rc=$?
  [ "$rc" -ne 0 ] || fail "a hardlinked source must refuse the push: $out"
  assert_contains "$out" "inherited source is hardlinked" "the refusal names the unsafe source"
  [ ! -s "$CF_LOG" ] || fail "a local refusal must send nothing, even items before it"$'\n'"$(cat "$CF_LOG")"
  pass "remote inheritance push: a local refusal is decided before any item is sent"
}

test_convergence_budget_isolates_a_hung_mate() {
  local out start elapsed
  convergence_fixture "$TMP_ROOT/convergence-budget" alpha:host-alpha bravo:host-bravo
  start=$(date +%s)
  out=$(
    PATH="$CF_FAKEBIN:$BASE_PATH" \
    FM_HOME="$CF_HOME" \
    FM_ROOT_OVERRIDE="$CF_PRIMARY" \
    FM_BOOTSTRAP_NETWORK=only \
    FM_SSH_BIN="$CF_FAKEBIN/fake-ssh" \
    FM_FAKE_SSH_LOG="$CF_LOG" \
    FM_FAKE_SYNC_HANG_HOST=host-alpha \
    FM_SECONDMATE_CONVERGENCE_TIMEOUT=15 \
    FM_INHERITABLE_CONFIG='item-a' \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1
  )
  elapsed=$(( $(date +%s) - start ))
  [ "$elapsed" -lt 90 ] || fail "a hung mate held the network phase for ${elapsed}s past its 15s budget"$'\n'"$out"
  assert_contains "$out" \
    "SECONDMATE_SYNC: secondmate alpha: skipped: remote tracked-file sync failed on host-alpha: no answer within the 15s per-mate convergence budget" \
    "the hung mate must be reported as its own skip"
  assert_contains "$out" \
    "SECONDMATE_SYNC: secondmate alpha: skipped: remote inheritance failed on host-alpha: no answer within the 15s per-mate convergence budget" \
    "an exhausted budget skips the hung mate's inheritance push too"
  assert_not_contains "$out" "SECONDMATE_SYNC: secondmate bravo:" "the healthy mate must converge without a skip"
  grep -q 'START host-bravo fm-remote-inherit.sh' "$CF_LOG" \
    || fail "the healthy mate's inheritance push did not run"$'\n'"$(cat "$CF_LOG")"
  [ -f "$CF_HOME/state/.secondmate-nudge-pending/alpha.pending" ] \
    || fail "the hung mate's retry marker must survive so the next session start retries it"
  assert_grep 'owed=1' "$CF_HOME/state/.secondmate-nudge-pending/alpha.pending" \
    "a step cut off by the budget may have changed the home, so the re-read must stay owed"
  [ ! -f "$CF_HOME/state/.secondmate-nudge-pending/bravo.pending" ] \
    || fail "the converged mate's retry marker must be cleared"
  pass "per-mate convergence budget: a hung host is that mate's skip, keeps its retry marker, and does not hold the others"
}

test_partial_push_failure_keeps_the_reread_owed() {
  local out
  convergence_fixture "$TMP_ROOT/partial-push-owed" alpha:host-alpha
  out=$(
    PATH="$CF_FAKEBIN:$BASE_PATH" \
    FM_HOME="$CF_HOME" \
    FM_ROOT_OVERRIDE="$CF_PRIMARY" \
    FM_BOOTSTRAP_NETWORK=only \
    FM_SSH_BIN="$CF_FAKEBIN/fake-ssh" \
    FM_FAKE_SSH_LOG="$CF_LOG" \
    FM_FAKE_ITEM_PUSHED=config/item-a \
    FM_FAKE_ITEM_FAIL=config/item-b \
    FM_REMOTE_INHERIT_PUSH_JOBS=1 \
    FM_INHERITABLE_CONFIG='item-a item-b' \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1
  )
  assert_contains "$out" \
    "SECONDMATE_SYNC: secondmate alpha: skipped: remote inheritance failed on host-alpha: error: synthetic refusal of config/item-b" \
    "the failed push must be reported with its own error"
  assert_grep 'owed=1' "$CF_HOME/state/.secondmate-nudge-pending/alpha.pending" \
    "an item the failed push already applied changed the home, so the re-read must stay owed"
  pass "a push that fails after applying an item keeps the mate's re-read owed"
}

test_remote_probe_scheduling_keeps_per_mate_lines parallel
test_remote_probe_scheduling_keeps_per_mate_lines fallback
test_remote_inheritance_failure_names_its_own_error_not_an_unchanged_item
test_inherit_push_overlaps_items_and_replays_in_order
test_inherit_push_failure_stops_new_sends
test_inherit_push_local_refusal_sends_nothing
test_convergence_budget_isolates_a_hung_mate
test_partial_push_failure_keeps_the_reread_owed
echo "# all fm-bootstrap-network-parallel tests passed"
