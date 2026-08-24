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
fm_git_identity fmtest fmtest@example.invalid

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
slow=0
case "$command_name" in
  fm-remote-doctor.sh) slow=1 ;;
  fm-remote-secondmate-control.sh)
    case "$subcommand" in state|sync) slow=1 ;; esac
    ;;
esac
if [ "$slow" -eq 1 ]; then
  printf 'START %s %s %s\n' "$host" "$command_name" "$subcommand" >> "$log"
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

test_concurrent_remote_probes_keep_per_mate_lines() {
  local dir home fakebin log out n doctor_overlap overlap liveness_starts fetch_starts
  local alpha_root alpha_home bravo_root bravo_home charlie_root charlie_home
  dir="$TMP_ROOT/parallel-lines"
  home="$dir/home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" gh treehouse tmux node
  log="$dir/probe.log"
  : > "$log"
  install_fake_ssh "$fakebin"
  install_slow_git "$fakebin" "$REAL_GIT" "$log"

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
    FM_BOOTSTRAP_NETWORK=only \
    FM_SSH_BIN="$fakebin/fake-ssh" \
    FM_FAKE_SSH_LOG="$log" \
    FM_FAKE_SSH_SLEEP=0.4 \
    FM_FAKE_SSH_UNREACHABLE_HOST=host-bravo \
    FM_FAKE_SSH_DIRTY_HOST=host-charlie \
    FM_FAKE_GIT_FETCH_SLEEP=0.4 \
    FM_INHERITABLE_CONFIG= \
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

  assert_not_contains "$out" \
    "SECONDMATE_LIVENESS: secondmate alpha: skipped: remote host unavailable or endpoint state unknown" \
    "a reachable mate must not inherit the unreachable mate's liveness skip"
  assert_not_contains "$out" \
    "SECONDMATE_SYNC: secondmate alpha: skipped: remote tracked-file sync failed" \
    "a clean reachable mate must not inherit the dirty mate's sync skip"

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
  [ "$doctor_overlap" -ge 2 ] \
    || fail "remote liveness probes did not overlap (starts before first doctor end=$doctor_overlap)"$'\n'"$(cat "$log")"

  liveness_starts=$(grep -c '^START .* fm-remote-secondmate-control.sh state$' "$log" || true)
  [ "$liveness_starts" -ge 2 ] \
    || fail "expected concurrent remote state probes, got $liveness_starts"$'\n'"$(cat "$log")"

  fetch_starts=$(grep -c '^START fleet-fetch ' "$log" || true)
  [ "$fetch_starts" -ge 1 ] \
    || fail "clone refresh did not start a fetch to overlap with secondmate probes"$'\n'"$(cat "$log")"
  overlap=$(awk '
    $1 == "START" { starts++ }
    $1 == "END" { print starts + 0; exit }
  ' "$log")
  [ "$overlap" -ge 2 ] \
    || fail "clone refresh did not overlap the secondmate sweeps (starts before first end=$overlap)"$'\n'"$(cat "$log")"

  pass "bootstrap network: concurrent remote probes keep per-mate lines and fail closed"
}

test_concurrent_remote_probes_keep_per_mate_lines
echo "# all fm-bootstrap-network-parallel tests passed"
