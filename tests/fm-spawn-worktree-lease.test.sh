#!/usr/bin/env bash
# Regression test for issue #2754: two concurrently-live tasks must never
# receive one treehouse pool slot.
#
# The incident: fm-spawn asked the pane's shell to run an interactive
# `treehouse get`, which holds its slot only while processes still run inside
# it. A parked worker whose occupant processes went quiet left firstmate's
# recorded worktree= pointing at a slot the pool considered free, so the next
# spawn on the same project received the SAME path and did its whole job
# inside another live task's copy.
#
# The fix: fm-spawn itself acquires the slot with `treehouse get --lease
# --lease-holder <task-id>`, whose durable lease survives process death until
# teardown's `treehouse return --force` releases it, then sends the pane into
# that exact path.
#
# The suite-owned fake tools model treehouse's documented allocation contract:
# a leased slot is never handed out by a later get until an explicit return;
# a plain interactive get's slot is protected only while an occupant process
# lives inside it, which the fixture models by never recording plain-get
# occupancy - exactly the parked-worker condition from the incident, under
# which the old in-pane flow handed both spawns the same slot.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-lease)

# make_lease_fakebin <dir>: builds the fakebin used by every case below.
#
# The treehouse stub keeps durable lease state in $FM_FAKE_TREEHOUSE_STATE:
# `get --lease --lease-holder H` records H against the first free slot and is
# never rehanded; a bare `get` allocates WITHOUT recording occupancy (transient
# process-based protection only); `return [--force] <path>` releases. The fake
# tmux follows commands like a real pane shell: send-keys text `cd <path>`
# moves the pane cwd file there, and send-keys text `treehouse get` performs
# the plain acquire before moving the pane to the slot it was handed.
# pane_current_path reads the cwd file, mirroring the OS-level read of a real
# pane.
make_lease_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")

  cat > "$fakebin/treehouse" <<SH
#!/usr/bin/env bash
set -u
STATE="\${FM_FAKE_TREEHOUSE_STATE:?FM_FAKE_TREEHOUSE_STATE unset}"
SLOTS="\$STATE/slots"
LEASES="\$STATE/leases"
case "\${1:-}" in
  get)
    holder=""
    if [ "\${2:-}" = --lease ] && [ "\${3:-}" = --lease-holder ]; then
      holder=\${4:-}
    fi
    if [ -n "\${FM_FAKE_LEASE_GET_STATUS:-}" ] && [ "\$FM_FAKE_LEASE_GET_STATUS" != 0 ]; then
      echo "fake treehouse: lease refused" >&2
      exit "\$FM_FAKE_LEASE_GET_STATUS"
    fi
    name="" path=""
    while IFS='|' read -r n p; do
      [ -n "\$n" ] || continue
      grep -q "|\$n\$" "\$LEASES" 2>/dev/null && continue
      name=\$n
      path=\$p
      break
    done < "\$SLOTS"
    if [ -z "\$name" ]; then
      echo "fake treehouse: no free slot" >&2
      exit 1
    fi
    if [ -n "\$holder" ]; then
      printf '%s|%s\n' "\$holder" "\$name" >> "\$LEASES"
    fi
    printf '%s\n' "\$path"
    exit 0
    ;;
  return)
    target=""
    for a in "\${@:2}"; do
      case "\$a" in --*) ;; *) target=\$a ;; esac
    done
    n=\$(printf '%s' "\$target" | sed 's|.*/||')
    if [ -f "\$LEASES" ]; then
      grep -v "|\$n\$" "\$LEASES" > "\$LEASES.tmp" 2>/dev/null || true
      mv "\$LEASES.tmp" "\$LEASES"
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse"

  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
CWD_FILE="\${FM_FAKE_PANE_CWD_FILE:?FM_FAKE_PANE_CWD_FILE unset}"
case "\$*" in
  *"#{pane_current_path}"*) cat "\$CWD_FILE"; exit 0 ;;
esac
case "\${1:-}" in
  display-message) printf 'firstmate\\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    text="" prev=""
    for a in "\$@"; do
      if [ "\$prev" != "-l" ] && [ "\$a" = "Enter" ]; then
        text=\$prev
        break
      fi
      prev=\$a
    done
    case "\$text" in
      'treehouse get')
        slot=\$(FM_FAKE_TREEHOUSE_STATE="\$FM_FAKE_TREEHOUSE_STATE" \\
          "$fakebin/treehouse" get)
        printf '%s\\n' "\$slot" > "\$CWD_FILE"
        ;;
      cd*)
        target=\${text#cd }
        case "\$target" in
          \'*\') target=\${target#\'} ; target=\${target%\'} ;;
        esac
        printf '%s\\n' "\$target" > "\$CWD_FILE"
        ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"

  printf '%s\n' "$fakebin"
}

make_lease_case() {
  local name=$1 id_a=$2 id_b=$3 case_dir home proj wt1 wt2 state
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt1="$case_dir/pool/1"
  wt2="$case_dir/pool/2"
  state="$case_dir/thstate"
  fakebin=$(make_lease_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config" "$state" "$case_dir/pool"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt1" "pool-1-$name"
  git -C "$proj" worktree add -q --detach "$wt2" >/dev/null 2>&1
  printf '1|%s\n2|%s\n' "$wt1" "$wt2" > "$state/slots"
  : > "$state/leases"
  printf '%s\n' "$proj" > "$case_dir/pane-cwd"
  for id in "$id_a" "$id_b"; do
    mkdir -p "$home/data/$id"
    printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  done
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt1|$wt2|$fakebin|$state|$case_dir/pane-cwd"
}

read_lease_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT1 WT2 FAKEBIN_DIR TH_STATE PANE_CWD <<EOF
$1
EOF
}

run_lease_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_CWD_FILE="$PANE_CWD" FM_FAKE_TREEHOUSE_STATE="$TH_STATE" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# Core regression (#2754): spawning task B on the same project while task A is
# still live must never hand B task A's slot. Under the old in-pane
# `treehouse get` flow the fixture's expired transient occupancy makes BOTH
# spawns record pool/1 - the double assignment this test forbids. With the
# durable lease each spawn holds its own exclusive slot until teardown
# returns it.
test_two_live_tasks_never_share_one_slot() {
  local rec id_a id_b out status
  id_a=lease-live-a-m1
  id_b=lease-live-b-m2
  rec=$(make_lease_case lease-two-live "$id_a" "$id_b")
  read_lease_record "$rec"

  out=$(run_lease_spawn "$id_a"); status=$?
  expect_code 0 "$status" "spawn A should succeed"
  assert_contains "$out" "spawned $id_a" "spawn A did not report success"
  assert_grep "worktree=$WT1" "$HOME_DIR/state/$id_a.meta" \
    "spawn A should hold pool slot 1"
  assert_contains "$(cat "$TH_STATE/leases")" "$id_a|1" \
    "allocator state should show a durable lease held by spawn A"

  out=$(run_lease_spawn "$id_b"); status=$?
  expect_code 0 "$status" "spawn B should succeed while task A is live"
  assert_grep "worktree=$WT2" "$HOME_DIR/state/$id_b.meta" \
    "spawn B must receive its own distinct leased slot"
  assert_no_grep "worktree=$WT1" "$HOME_DIR/state/$id_b.meta" \
    "spawn B must never be recorded inside spawn A's slot"
  assert_contains "$(cat "$TH_STATE/leases")" "$id_b|2" \
    "allocator state should show a durable lease held by spawn B"
  pass "two concurrently-live tasks never share one pool slot (durable leases)"
}

# An allocator refusal must stop the spawn loudly before any worker launches,
# rather than falling back to an unleased or shared slot.
test_lease_refusal_stops_the_spawn() {
  local rec id out status
  id=lease-refused-n3
  rec=$(make_lease_case lease-refused "$id" unused-b)
  read_lease_record "$rec"

  out=$(FM_FAKE_LEASE_GET_STATUS=28 run_lease_spawn "$id"); status=$?
  expect_code 1 "$status" "a refused lease must abort the spawn"
  assert_contains "$out" "--lease" "refusal error should name the lease acquisition"
  [ ! -f "$HOME_DIR/state/$id.meta" ] || fail "refused spawn must not publish meta"
  pass "an allocator refusal stops the spawn before launch (fail closed)"
}

# A spawn that aborts AFTER acquiring its lease (here: the pooled worktree's
# base refresh refuses an unreachable origin) must release the lease again, so
# a failed launch cannot silently shrink the pool.
test_aborted_spawn_releases_its_lease() {
  local rec id out status
  id=lease-abort-release-p4
  rec=$(make_lease_case lease-abort "$id" unused-b)
  read_lease_record "$rec"
  git -C "$WT1" remote set-url origin "file://$CASE_DIR/missing-origin.git"

  out=$(run_lease_spawn "$id"); status=$?
  expect_code 1 "$status" "an unreachable origin must abort the spawn after the lease"
  assert_contains "$out" "could not fetch origin" \
    "abort did not name the base-refresh refusal"
  [ ! -s "$TH_STATE/leases" ] || fail "an aborted spawn must release its treehouse lease"
  pass "a spawn aborted after acquisition releases its pool slot lease"
}

test_two_live_tasks_never_share_one_slot
test_lease_refusal_stops_the_spawn
test_aborted_spawn_releases_its_lease

echo "# all fm-spawn-worktree-lease tests passed"
