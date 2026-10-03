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
#
# One scheduling property is a contract of its own and is covered here too:
# when config/ssh-launch-stagger-host names a remote host, repeated launches to
# that host are spaced, while every other host and every local launch still
# starts immediately; when the file is absent, no launch is ever spaced. See
# run_stagger_scenario and the tests below.
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
  if [ -n "${FM_FAKE_SSH_TIMING_LOG:-}" ]; then
    printf '%s %s %s %s\n' "$host" "$command_name" "$(python3 -c 'import time; print(time.time())')" "$subcommand" >> "$FM_FAKE_SSH_TIMING_LOG"
  fi
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

test_remote_probe_scheduling_keeps_per_mate_lines parallel
test_remote_probe_scheduling_keeps_per_mate_lines fallback
test_remote_inheritance_failure_names_its_own_error_not_an_unchanged_item

# Launch-stagger regression: bootstrap_parallel_spawn (bin/fm-bootstrap.sh)
# makes the Nth worker of a concurrent batch bound for the host named in
# config/ssh-launch-stagger-host wait 0.4s * (N-1) after its own fork before
# it starts, so simultaneous cold SSH connections to that host's sshd do not
# collide with its connection-rate limit. It applies to no other host, and
# because the wait lives in the worker the parent dispatch loop never blocks.
# When the config file is absent, no launch is ever spaced - that is today's
# unchanged upstream default.
#
# What the spacing controls is the instant each worker's first remote call
# leaves, so the signal to assert on is the spacing between the probes of one
# batch, not the wall clock of a whole run. The convergence batch
# (secondmate_sync) is used: each worker goes straight out over SSH, so the
# spacing survives to the fake SSH as the arrival spacing of the `sync`
# probes.
STAGGER_TEST_IDS="alpha bravo charlie"
STAGGER_TEST_HOST="test-stagger-host"

run_stagger_scenario() { # <dir> <label> <hosts-are-distinct 0|1> <config-present 0|1> -> sets STAGGER_OUT, STAGGER_TIMING_LOG
  local dir=$1 label=$2 distinct=$3 configured=$4
  local id host log timing_log root home fakebin
  log="$dir/$label/probe.log"
  timing_log="$dir/$label/timing.log"
  mkdir -p "$dir/$label/home/state" "$dir/$label/home/data" "$dir/$label/home/config" "$dir/$label/home/projects"
  : > "$dir/$label/home/data/secondmates.md"
  if [ "$configured" -eq 1 ]; then
    printf '%s\n' "$STAGGER_TEST_HOST" > "$dir/$label/home/config/ssh-launch-stagger-host"
  fi
  for id in $STAGGER_TEST_IDS; do
    if [ "$distinct" -eq 1 ]; then host="host-$id"; else host="$STAGGER_TEST_HOST"; fi
    root="$dir/$label/remote/$id/root"
    home="$dir/$label/remote/$id/home"
    mkdir -p "$root" "$home"
    write_remote_registry_line "$dir/$label/home/data/secondmates.md" "$id" "$host" "$root" "$home"
    fm_write_secondmate_meta "$dir/$label/home/state/$id.meta" "$home"
    printf 'remote_host=%s\n' "$host" >> "$dir/$label/home/state/$id.meta"
  done
  fm_git_init_commit "$dir/$label/home/projects/alpha"
  fm_git_add_origin "$dir/$label/home/projects/alpha" "$dir/$label/alpha.origin.git"
  : > "$log"
  : > "$timing_log"
  # A per-scenario fakebin: install_slow_git bakes its log path into the
  # generated git wrapper at install time, so two scenarios sharing one
  # fakebin would have the second install silently overwrite the first
  # wrapper's target log.
  fakebin=$(fm_fakebin "$dir/$label")
  fm_fake_exit0 "$fakebin" gh treehouse tmux node
  install_fake_ssh "$fakebin"
  install_slow_git "$fakebin" "$REAL_GIT" "$log"
  STAGGER_OUT=$(
    PATH="$fakebin:$BASE_PATH" \
    FM_HOME="$dir/$label/home" \
    FM_ROOT_OVERRIDE="$dir/primary" \
    FM_BOOTSTRAP_NETWORK=only \
    FM_SSH_BIN="$fakebin/fake-ssh" \
    FM_FAKE_SSH_LOG="$log" \
    FM_FAKE_SSH_TIMING_LOG="$timing_log" \
    FM_FAKE_SSH_SLEEP=0.02 \
    FM_FAKE_SSH_UNREACHABLE_HOST=no-such-host \
    FM_FAKE_SSH_FAIL_HOST=no-such-host \
    FM_FAKE_SSH_DIRTY_HOST=no-such-host \
    FM_FAKE_GIT_FETCH_SLEEP=0.02 \
    FM_BOOTSTRAP_VERBOSE_FACTS=1 \
    FM_INHERITABLE_CONFIG='' \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1
  )
  STAGGER_TIMING_LOG=$timing_log
}

stagger_seed_primary() { # <dir>
  local primary="$1/primary"
  mkdir -p "$primary"
  git init -q -b main "$primary"
  cp -R "$ROOT/bin" "$primary/bin"
  printf 'test primary\n' > "$primary/AGENTS.md"
  git -C "$primary" add AGENTS.md bin
  git -C "$primary" commit -qm 'seed primary default branch'
}

# Compares one staggered batch against one jitter-only control batch from the
# same test and prints their spacing; exits nonzero naming every problem. The
# arrival instant of each worker's first `sync` probe is not the stagger sleep
# itself: each worker still runs lock, generation, and nudge setup first, and
# the fake SSH starts Python before it records its timestamp. On a quiet host
# a staggered gap lands near 0.4s and an unstaggered batch spans a few
# hundredths of a second. On a busy runner the first worker is often cold and
# later ones warm, so one staggered gap can compress well below 0.4s, while an
# unstaggered batch can stretch past 0.3s. No single fixed threshold holds
# between those two populations, so several signals are read together:
# - the staggered batch's mean gap and total span must stay a clear fraction
#   of the configured delay, which catches a removed or weakened stagger even
#   when one gap compresses;
# - a soft per-gap floor of an eighth of the delay (0.05s) still rejects two
#   staggered workers that truly started together, while leaving room for
#   cold or warm setup skew to compress a single gap;
# - the staggered mean gap must exceed the whole control span on the same run,
#   which separates delay-dominated spacing from jitter without a fixed ratio
#   that would flake when load stretches both batches together;
# - the control span must stay below a soft ceiling that a staggered batch
#   spanning 0.4s * (N-1) would still exceed even with one compressed gap.
stagger_spacing_report() { # <staggered-timing-log> <control-timing-log> <control-label> <launches>
  python3 - "$@" <<'PYSPACING'
import sys

STAGGER_DELAY = 0.4
MIN_STAGGERED_MEAN_GAP = STAGGER_DELAY * 0.5       # 0.20s
MIN_STAGGERED_SPAN_FRACTION = 0.5                  # span >= 0.5 * (n-1) * delay
MIN_STAGGERED_GAP = STAGGER_DELAY * 0.125          # 0.05s soft floor
MAX_CONTROL_SPAN_FRACTION = 0.75                   # span < 0.75 * (n-1) * delay


def convergence_launches(path):
    stamps = []
    with open(path) as handle:
        for line in handle:
            fields = line.split()
            if (len(fields) == 4 and fields[1] == "fm-remote-secondmate-control.sh"
                    and fields[3] == "sync"):
                stamps.append(float(fields[2]))
    return sorted(stamps)


def gaps(stamps):
    return [later - earlier for earlier, later in zip(stamps, stamps[1:])]


def span(stamps):
    return (stamps[-1] - stamps[0]) if len(stamps) > 1 else 0.0


staggered_log, control_log, control_label, want = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
staggered, control = convergence_launches(staggered_log), convergence_launches(control_log)
staggered_gaps, control_gaps = gaps(staggered), gaps(control)
staggered_span, control_span = span(staggered), span(control)
mean_gap = (sum(staggered_gaps) / len(staggered_gaps)) if staggered_gaps else 0.0
ideal_span = STAGGER_DELAY * max(want - 1, 0)

problems = []
if len(staggered) != want:
    problems.append("staggered batch made %d convergence launches, want %d" % (len(staggered), want))
if len(control) != want:
    problems.append("%s batch made %d convergence launches, want %d" % (control_label, len(control), want))
if staggered_gaps and mean_gap < MIN_STAGGERED_MEAN_GAP:
    problems.append("repeated-host launches were not staggered: mean gap %.3fs < %.2fs"
                    % (mean_gap, MIN_STAGGERED_MEAN_GAP))
if len(staggered) > 1 and staggered_span < ideal_span * MIN_STAGGERED_SPAN_FRACTION:
    problems.append("repeated-host launches were not staggered: span %.3fs < %.2fs"
                    % (staggered_span, ideal_span * MIN_STAGGERED_SPAN_FRACTION))
if staggered_gaps and min(staggered_gaps) < MIN_STAGGERED_GAP:
    problems.append("repeated-host launches shared a start instant: smallest gap %.3fs < %.2fs"
                    % (min(staggered_gaps), MIN_STAGGERED_GAP))
if staggered_gaps and mean_gap <= control_span:
    problems.append("%s launches were spaced like staggered ones: span %.3fs >= staggered mean gap %.3fs"
                    % (control_label, control_span, mean_gap))
if len(control) > 1 and control_span >= ideal_span * MAX_CONTROL_SPAN_FRACTION:
    problems.append("%s launches lost their parallelism: span %.3fs >= %.2fs"
                    % (control_label, control_span, ideal_span * MAX_CONTROL_SPAN_FRACTION))

print("staggered gaps=%s mean=%.3f span=%.3f %s gaps=%s span=%.3f"
      % (["%.3f" % gap for gap in staggered_gaps], mean_gap, staggered_span, control_label,
         ["%.3f" % gap for gap in control_gaps], control_span))
for problem in problems:
    print(problem)
raise SystemExit(1 if problems else 0)
PYSPACING
}

test_remote_probe_launch_stagger_when_configured() {
  local dir id spacing n
  dir="$TMP_ROOT/stagger-configured"
  stagger_seed_primary "$dir"

  run_stagger_scenario "$dir" repeat 0 1
  local out_rep=$STAGGER_OUT timing_rep=$STAGGER_TIMING_LOG
  run_stagger_scenario "$dir" distinct 1 1
  local out_dist=$STAGGER_OUT timing_dist=$STAGGER_TIMING_LOG

  for id in $STAGGER_TEST_IDS; do
    assert_contains "$out_rep" "BOOTSTRAP_INFO: remote secondmate $id already live" \
      "repeat batch: secondmate $id (repeated host) must still report success"
    assert_contains "$out_dist" "BOOTSTRAP_INFO: remote secondmate $id already live" \
      "distinct batch: secondmate $id (its own host) must still report success"
  done

  n=$(grep -c "^${STAGGER_TEST_HOST} fm-remote-doctor.sh " "$timing_rep" || true)
  [ "$n" -eq 3 ] \
    || fail "repeat batch: expected exactly 3 readiness probes to the configured host (no retry), got $n"$'\n'"$(cat "$timing_rep")"

  # The distinct-host batch is the jitter-only control: same config, same
  # size, but no host repeats, so nothing in it may be spaced.
  spacing=$(stagger_spacing_report "$timing_rep" "$timing_dist" distinct-host 3) \
    || fail "launch spacing did not isolate the configured-host stagger"$'\n'"$spacing"

  if [ -n "${FM_TEST_EVIDENCE_FILE:-}" ]; then
    {
      printf '=== configured-host repeat batch output ===\n%s\n' "$out_rep"
      printf '=== configured-host distinct batch output ===\n%s\n' "$out_dist"
      printf '=== convergence launch spacing ===\n%s\n' "$spacing"
    } >> "$FM_TEST_EVIDENCE_FILE"
  fi

  pass "bootstrap network launch stagger (config present): $spacing - repeated launches to the configured host are staggered, other hosts stay parallel, no retry"
}

test_remote_probe_launch_stagger_when_absent() {
  local dir id spacing n
  dir="$TMP_ROOT/stagger-absent"
  stagger_seed_primary "$dir"

  run_stagger_scenario "$dir" repeat 0 0
  local out_rep=$STAGGER_OUT timing_rep=$STAGGER_TIMING_LOG
  # The same repeated-host batch with the config file present is the
  # staggered reference on this run, so the absent-config batch is judged
  # against real stagger spacing under the same load rather than a fixed
  # arrival window.
  run_stagger_scenario "$dir" reference 0 1
  local timing_ref=$STAGGER_TIMING_LOG

  for id in $STAGGER_TEST_IDS; do
    assert_contains "$out_rep" "BOOTSTRAP_INFO: remote secondmate $id already live" \
      "repeat batch with no config file: secondmate $id must still report success"
  done

  n=$(grep -c "^${STAGGER_TEST_HOST} fm-remote-doctor.sh " "$timing_rep" || true)
  [ "$n" -eq 3 ] \
    || fail "repeat batch with no config file: expected exactly 3 readiness probes, got $n"$'\n'"$(cat "$timing_rep")"

  spacing=$(stagger_spacing_report "$timing_ref" "$timing_rep" absent-config 3) \
    || fail "an absent config file unexpectedly staggered launches"$'\n'"$spacing"

  if [ -n "${FM_TEST_EVIDENCE_FILE:-}" ]; then
    {
      printf '=== absent-config repeat batch output ===\n%s\n' "$out_rep"
      printf '=== convergence launch spacing ===\n%s\n' "$spacing"
    } >> "$FM_TEST_EVIDENCE_FILE"
  fi

  pass "bootstrap network launch stagger (config absent): $spacing - repeated launches to the same host are never staggered without the config file"
}

test_remote_probe_launch_stagger_when_configured
test_remote_probe_launch_stagger_when_absent
echo "# all fm-bootstrap-network-parallel tests passed"
