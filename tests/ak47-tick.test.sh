#!/usr/bin/env bash
# tests/ak47-tick.test.sh - the deterministic tick, and the refusals that matter.
#
# The tick is the only part of this system that removes anything, so the tests
# that matter are the ones where it declines. Every case below builds a real
# tree, puts a real live process in it, and asserts the tick left it alone.
#
# Hermetic: AK47_TMP_ROOT points the tick at a mktemp tree, and AK47_STATE,
# AK47_CACHE and AK47_CONFIG all point inside it. Nothing reads or writes the
# real /tmp or the real ~/.local/state/ak47.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TICK="$ROOT/ak47/tick.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

SANDBOX=
cleanup() {
  # Kill any holder subshell this suite started before removing the tree.
  [ -n "${HOLDER_PID:-}" ] && kill "$HOLDER_PID" 2>/dev/null
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"
}
trap cleanup EXIT
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/ak47-tick-tests.XXXXXX")

export AK47_STATE=$SANDBOX/state
export AK47_CACHE=$SANDBOX/cache
export AK47_CONFIG=$SANDBOX/config
export AK47_TMP_ROOT=$SANDBOX/tmp
export FM_HOME=$SANDBOX/fmhome
mkdir -p "$AK47_STATE" "$AK47_CACHE" "$AK47_CONFIG" "$AK47_TMP_ROOT" "$FM_HOME/state" "$FM_HOME/bin"

# A config that makes every class fire immediately, so the tests do not have to
# wait a day for a leak to age.
write_config() {
  cat >"$AK47_CONFIG/devops.conf" <<'CONF'
tmp_mktemp_min=0
tmp_producer_min=0
orphan_min=0
quarantine_days=7
# 0 means "the tree is always over its ceiling", so every class fires in the
# fixture without the test having to build 200,000 entries.
tmp_max_entries=0
tmp_max_moves=2000
swap_pressure=0
fat_process=0
fat_process_gb=3
fat_process_min=10
interval_seconds=300
CONF
}

# Age a path so the age gate passes without waiting.
age() { touch -d '3 days ago' "$1"; }

reset_tree() {
  rm -rf "$AK47_TMP_ROOT" "$AK47_STATE"
  mkdir -p "$AK47_TMP_ROOT" "$AK47_STATE"
  write_config
}


# --- expiry must be bounded and must not shell out per directory ------------------
# 2026-11-14: an expired quarantine dir large enough to matter made `lsof +D` run
# past the unit's start timeout, so nothing was ever deleted and the loop logged
# nothing. Both properties are asserted here.

test_expiry_is_bounded_per_run_and_says_what_is_left() {
  reset_tree
  printf 'quarantine_expire_max=3\n' >>"$AK47_CONFIG/devops.conf"
  local day=$AK47_STATE/quarantine/20200101 i
  mkdir -p "$day"
  for i in 1 2 3 4 5; do mkdir -p "$day/entry-$i"; printf 'x\n' >"$day/entry-$i/f"; done
  "$TICK" --apply >/dev/null 2>&1 || fail "tick exited non-zero"
  local left; left=$(find "$day" -mindepth 1 -maxdepth 1 | wc -l)
  [ "$left" -eq 2 ] || fail "the per-run bound did not apply: $left of 5 entries remain, expected 2"
  tail -n 1 "$AK47_STATE/devops.log" | grep -q 'expire_pending=2' \
    || fail "the tick line does not say how many expired entries it deferred"
  pass "expiry deletes at most quarantine_expire_max per run and reports the remainder"
}

test_expiry_does_not_run_lsof_per_entry() {
  reset_tree
  # A hostile lsof: if the tick consults it per quarantine entry, this exits
  # non-zero with an error, which safe-delete reads as "could not tell" and the
  # delete is refused. With the in-use set in place lsof is never called.
  local stub=$SANDBOX/lsofstub day=$AK47_STATE/quarantine/20200101
  mkdir -p "$stub" "$day/entry-1"
  printf '#!/bin/sh\necho "lsof should not be called for a quarantine entry" >&2\nexit 2\n' >"$stub/lsof"
  chmod +x "$stub/lsof"
  printf 'x\n' >"$day/entry-1/f"
  PATH="$stub:$PATH" "$TICK" --apply >/dev/null 2>&1 || fail "tick exited non-zero"
  [ -e "$day/entry-1" ] && fail "the expired entry survived: the tick fell back to a per-entry lsof scan"
  pass "the tick deletes an expired entry without running lsof on it"
}


test_an_unprivileged_tick_says_so_instead_of_failing_to_swap() {
  # The tick is a user unit: swapoff and swapon are root-only. If it just tried,
  # every tick on a full swap would WARN and count a failure while swap stayed
  # full - a capability it does not have, reported as a transient error. It must
  # prove it can swap first, then file the one line that grants the capability.
  local box
  box=$(mktemp -d "${TMPDIR:-/tmp}/ak47-swappriv.XXXXXX")
  mkdir -p "$box/bin"
  printf '#!/bin/sh\necho called >>"%s/swapoff.calls"\nexit 0\n' "$box" >"$box/bin/swapoff"
  printf '#!/bin/sh\nexit 0\n' >"$box/bin/swapon"
  chmod +x "$box/bin/swapoff" "$box/bin/swapon"
  {
    printf 'SwapTotal:      33554428 kB\n'
    printf 'SwapFree:         335544 kB\n'
    printf 'MemAvailable:   90000000 kB\n'
  } >"$box/meminfo"
  # The sandbox conf arms the reclaim, so the only thing stopping it is privilege.
  sed -i 's/^swap_pressure=.*/swap_pressure=1/' "$SANDBOX/config/devops.conf"
  PATH="$box/bin:$PATH" AK47_SWAP_PRIVILEGE=no AK47_MEMINFO="$box/meminfo" \
    "$ROOT/ak47/tick.sh" --apply >/dev/null 2>&1
  sed -i 's/^swap_pressure=.*/swap_pressure=0/' "$SANDBOX/config/devops.conf"
  [ -s "$box/swapoff.calls" ] && fail "an unprivileged tick tried to run swapoff anyway"
  grep -q '^.*swap-unprivileged ' "$SANDBOX/state/findings.log" 2>/dev/null \
    || fail "the tick did not report that reclaiming swap needs root"
  rm -rf "$box"
  pass "an unprivileged tick reports the missing privilege instead of failing to swap"
}

test_a_privileged_tick_rings_the_reclaim_and_does_not_swap_inline() {
  # swapoff -a on a full swap takes tens of minutes, so a tick that ran it would
  # be killed at its own start timeout - half way through, which is the one state
  # the always-restore rule exists to avoid. A privileged tick must ring the
  # separate unit and leave the swapping to it.
  box=$(mktemp -d "${TMPDIR:-/tmp}/ak47-swapunit.XXXXXX")
  printf '#!/bin/sh\necho "$*" >>"%s/systemctl.calls"\ncase "$*" in *is-active*) exit 3 ;; esac\nexit 0\n' "$box" >"$box/systemctl"
  printf '#!/bin/sh\necho called >>"%s/swapoff.calls"\nexit 0\n' "$box" >"$box/swapoff"
  printf '#!/bin/sh\nexit 0\n' >"$box/swapon"
  chmod +x "$box/systemctl" "$box/swapoff" "$box/swapon"
  printf 'SwapTotal:      33554428 kB\nSwapFree:         335544 kB\nMemAvailable:  90000000 kB\n' >"$box/meminfo"
  sed -i 's/^swap_pressure=.*/swap_pressure=1/' "$SANDBOX/config/devops.conf"
  PATH="$box:$PATH" AK47_SWAP_PRIVILEGE=yes AK47_SYSTEMCTL="$box/systemctl" \
    AK47_SWAPON="$box/swapon" AK47_SWAPOFF="$box/swapoff" AK47_MEMINFO="$box/meminfo" \
    AK47_DU_BUDGET=2 "$ROOT/ak47/tick.sh" --apply >"$box/tick.out" 2>&1
  sed -i 's/^swap_pressure=.*/swap_pressure=0/' "$SANDBOX/config/devops.conf"
  grep -q 'start --no-block ak47-swap-reclaim.service' "$box/systemctl.calls" 2>/dev/null \
    || fail "a privileged tick did not ring ak47-swap-reclaim.service: $(tail -2 "$box/tick.out") $(cat "$box/systemctl.calls" 2>/dev/null)"
  [ -s "$box/swapoff.calls" ] && fail "the tick ran swapoff inline instead of leaving it to the unit"
  pass "a privileged tick rings the reclaim unit and never swaps inline"
}

test_swap_is_restored_even_when_the_reclaim_fails() {
  # swapoff -a && swapon -a has two failure modes that only appear when it goes
  # wrong: a tick killed between the two calls leaves the box with no swap, and
  # the next run's swapoff fails instantly because nothing is on - so the &&
  # chain can never turn swap back on. Swap must be restored either way.
  local box
  box=$(mktemp -d "${TMPDIR:-/tmp}/ak47-swap.XXXXXX")
  mkdir -p "$box/bin"
  printf '#!/bin/sh\nexit 1\n' >"$box/bin/swapoff"
  printf '#!/bin/sh\necho on >>"%s/swapon.calls"\n' "$box" >"$box/bin/swapon"
  printf "#!/bin/sh\n[ \"\$1\" = -n ] && shift\necho \"\$*\" >>\"%s/sudo.calls\"\nexec \"\$@\"\n" "$box" >"$box/bin/sudo"
  chmod +x "$box/bin/swapoff" "$box/bin/swapon" "$box/bin/sudo"
  cat >"$box/reclaim.sh" <<'SH'
. "$1/ak47/lib/common.sh"
swap_reclaim
printf 'rc=%s\n' "$?"
SH
  PATH="$box/bin:$PATH" AK47_STATE="$box/state" \
    AK47_SWAPOFF="$box/bin/swapoff" AK47_SWAPON="$box/bin/swapon" \
    bash "$box/reclaim.sh" "$ROOT" >/dev/null 2>&1
  [ -s "$box/swapon.calls" ] || fail "a failed swapoff left swap off for good"
  grep -q "$box/bin/swapoff" "$box/sudo.calls" 2>/dev/null \
    || fail "swap_reclaim ran the root-only command without the documented sudo grant"
  rm -rf "$box"
  pass "swap is turned back on even when the reclaim itself fails"
}

test_swap_privilege_probes_the_granted_command() {
  # The documented sudoers rule grants only /sbin/swapoff -a and /sbin/swapon -a.
  # A probe of `sudo -n true` is outside that grant and always denied, so the
  # capability must be proven with a command the rule actually carries.
  local box
  box=$(mktemp -d "${TMPDIR:-/tmp}/ak47-swappriv-probe.XXXXXX")
  mkdir -p "$box/bin"
  printf "#!/bin/sh\n[ \"\$1\" = -n ] && shift\ncase \"\$1\" in */swapon|*/swapoff) exit 0 ;; *) exit 1 ;; esac\n" \
    >"$box/bin/sudo"
  printf '#!/bin/sh\nexit 0\n' >"$box/bin/swapon"
  chmod +x "$box/bin/sudo" "$box/bin/swapon"
  cat >"$box/probe.sh" <<'SH'
. "$1/ak47/lib/common.sh"
swap_privileged
SH
  PATH="$box/bin:$PATH" AK47_STATE="$box/state" AK47_SWAPON="$box/bin/swapon" \
    bash "$box/probe.sh" "$ROOT" \
    || { rm -rf "$box"; fail "the privilege probe did not accept the grant the README installs"; }
  rm -rf "$box"
  pass "the swap privilege probe asks for a command the sudoers rule grants"
}

test_a_finding_is_delivered_to_the_real_inbox() {
  # Every ak47 finding went undelivered for days because the tick filed under a
  # class name fm-inbox does not have. The gate was honest - it logged
  # DELIVERY-FAILED every run - but nothing was reading the gate's own log. This
  # drives the real inbox: a finding must land as a record in its queue and the
  # tick must not report a delivery failure.
  reset_tree
  [ -r "$ROOT/bin/fm-inbox.sh" ] || { pass "no fm-inbox.sh in this checkout, delivery check skipped"; return; }
  cp "$ROOT/bin/fm-inbox.sh" "$FM_HOME/bin/fm-inbox.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$FM_HOME/bin/fm-wake-lib.sh"
  chmod +x "$FM_HOME/bin/fm-inbox.sh"
  # A lock naming a pid that cannot be alive triggers the stale-lock finding.
  printf '999999999\n' >"$FM_HOME/state/.lock"
  "$TICK" --apply >/dev/null 2>&1 || fail "tick exited non-zero while filing a finding"
  local note
  note=$(find "$FM_HOME/state/inbox-auto" -maxdepth 1 -name '*.note' -print -quit 2>/dev/null)
  [ -n "$note" ] || fail "the tick's finding never reached the inbox"
  grep -qx 'source=health' "$note" || fail "the finding was filed under a class the inbox rewrote"
  grep -q 'state/.lock names pid' "$note" || fail "the delivered note does not carry the finding"
  ! grep -q 'DELIVERY-FAILED' "$AK47_STATE/findings.log" 2>/dev/null \
    || fail "the tick reported a delivery failure for a class the inbox accepts"
  pass "a finding is delivered to the real inbox under an accepted class"
}

# --- the refusals ---------------------------------------------------------------


# --- the sampler must be bounded -------------------------------------------------
# 2026-11-14: `du` over 698 GB of /tmp stopped finishing, the cached value went
# stale, and every run blocked until systemd TERMed the unit - hours of silence
# with nothing in devops.log. A bounded tick may not call an unbounded sampler.

test_a_size_walk_that_overruns_does_not_hang_the_tick() {
  reset_tree
  local slow=$SANDBOX/slowbin
  mkdir -p "$slow"
  printf '#!/bin/sh\nexec sleep 300\n' >"$slow/du"
  chmod +x "$slow/du"
  local start; start=$(date +%s)
  PATH="$slow:$PATH" AK47_DU_BUDGET=2 "$TICK" --apply >/dev/null 2>&1 \
    || fail "the tick exited non-zero when the size walk overran"
  local took=$(( $(date +%s) - start ))
  [ "$took" -lt 60 ] || fail "the tick blocked for ${took}s on a size walk that does not finish"
  [ "$(wc -l <"$AK47_STATE/devops.log")" -eq 1 ] \
    || fail "the tick did not write its line when the size walk overran"
  pass "a size walk that overruns is cut off instead of hanging the tick"
}

test_an_unmeasurable_tree_is_a_finding_not_silence() {
  reset_tree
  local slow=$SANDBOX/slowbin2
  mkdir -p "$slow"
  printf '#!/bin/sh\nexec sleep 300\n' >"$slow/du"
  chmod +x "$slow/du"
  # A tree with something in it: an empty tree is measurable (0 GB) and would
  # never exercise the walk at all.
  mkdir -p "$AK47_TMP_ROOT/uvn-old"; head -c 200000 /dev/zero >"$AK47_TMP_ROOT/uvn-old/blob"
  # A successful measurement from long ago, and a walk that no longer finishes.
  printf 'tmp_gb\t%s\t999\n' $(( $(date +%s) - 100000 )) >"$AK47_STATE/sample.cache"
  printf 'tmp_gb_ok\t%s\t%s\n' $(( $(date +%s) - 100000 )) $(( $(date +%s) - 100000 )) >>"$AK47_STATE/sample.cache"
  PATH="$slow:$PATH" AK47_DU_BUDGET=2 AK47_DU_TTL=60 "$TICK" --apply >/dev/null 2>&1 \
    || fail "the tick exited non-zero with a stale size cache"
  grep -q tmp-gb-stale "$AK47_STATE/findings.log" 2>/dev/null \
    || fail "an unmeasurable /tmp produced no finding; the sweep would choose from a stale picture"
  pass "a tree that can no longer be measured is reported, not silently scored"
}

test_a_failed_size_walk_is_retried_once_its_window_elapses() {
  reset_tree
  local slow=$SANDBOX/slowbin3
  mkdir -p "$slow"
  printf '#!/bin/sh\necho x >>"%s/du-calls"\nexit 1\n' "$slow" >"$slow/du"
  chmod +x "$slow/du"
  mkdir -p "$AK47_TMP_ROOT/uvn-old"; head -c 200000 /dev/zero >"$AK47_TMP_ROOT/uvn-old/blob"
  PATH="$slow:$PATH" AK47_DU_BUDGET=2 "$TICK" --apply >/dev/null 2>&1 \
    || fail "the tick exited non-zero when the first size walk failed"
  [ "$(wc -l <"$slow/du-calls")" -ge 1 ] || fail "the first failed walk was not attempted"
  local calls; calls=$(wc -l <"$slow/du-calls")
  # Inside the retry window the fallback is used; once it elapses the walk is
  # due again even though the fallback value is still cached.
  PATH="$slow:$PATH" AK47_DU_BUDGET=2 AK47_DU_RETRY=0 "$TICK" --apply >/dev/null 2>&1 \
    || fail "the tick exited non-zero when retrying the size walk"
  [ "$(wc -l <"$slow/du-calls")" -gt "$calls" ] \
    || fail "the failed walk was never retried after its window elapsed"
  pass "a failed size walk is retried once its window elapses"
}

test_refuses_a_directory_a_live_process_is_sitting_in() {
  reset_tree
  local d=$AK47_TMP_ROOT/tmpa003ltt_
  mkdir -p "$d"; age "$d"
  # A real process whose cwd is inside the candidate. This is the case a
  # name-based sweeper gets wrong.
  ( cd "$d" && sleep 30 ) &
  HOLDER_PID=$!
  sleep 0.3
  "$TICK" --apply >/dev/null 2>&1 || fail "tick exited non-zero"
  [ -d "$d" ] || fail "tick removed a directory a live process was sitting in"
  kill "$HOLDER_PID" 2>/dev/null; wait "$HOLDER_PID" 2>/dev/null; HOLDER_PID=
  pass "tick refuses a directory a live process is sitting in"
}

test_refuses_a_directory_a_live_process_has_a_file_open_in() {
  reset_tree
  local d=$AK47_TMP_ROOT/tmpb004muu_
  mkdir -p "$d"
  printf 'held\n' >"$d/open.txt"
  age "$d"; age "$d/open.txt"
  # A process holding an open descriptor on a file inside the candidate. Its cwd
  # is elsewhere, so only a handle scan finds it.
  ( exec 3<"$d/open.txt"; sleep 30 ) &
  HOLDER_PID=$!
  sleep 0.3
  "$TICK" --apply >/dev/null 2>&1 || fail "tick exited non-zero"
  [ -d "$d" ] || fail "tick removed a directory holding an open file descriptor"
  kill "$HOLDER_PID" 2>/dev/null; wait "$HOLDER_PID" 2>/dev/null; HOLDER_PID=
  pass "tick refuses a directory holding an open file descriptor"
}

test_refuses_a_live_tasks_scratch_root() {
  reset_tree
  local d=$AK47_TMP_ROOT/fm-livetask
  mkdir -p "$d/gotmp" "$d/tmp"
  age "$d"
  # A live task record is the only thing that makes this scratch root live.
  printf 'window=x:fm-livetask\n' >"$FM_HOME/state/livetask.meta"
  "$TICK" --apply >/dev/null 2>&1 || fail "tick exited non-zero"
  [ -d "$d" ] || fail "tick removed a live task's scratch root"
  pass "tick refuses a live task's scratch root"
}

test_quarantines_an_orphaned_task_scratch_root() {
  reset_tree
  local d=$AK47_TMP_ROOT/fm-deadtask
  mkdir -p "$d/gotmp"
  age "$d"
  # No state/deadtask.meta: the task is gone, the scratch root is not.
  "$TICK" --apply >/dev/null 2>&1 || fail "tick exited non-zero"
  [ ! -e "$d" ] || fail "tick left an orphaned task scratch root in place"
  pass "tick quarantines an orphaned task scratch root"
}

test_refuses_every_named_protected_path() {
  reset_tree
  local name
  for name in fm-move ak47-state orcad-1 systemd-private-x snap-foo \
              .X11-unix .ICE-unix .font-unix .Test-unix .XIM-unix \
              cli-proxy-api.sock forwarder.token my-router.sh; do
    mkdir -p "$AK47_TMP_ROOT/$name"
    age "$AK47_TMP_ROOT/$name"
  done
  "$TICK" --apply >/dev/null 2>&1 || fail "tick exited non-zero"
  for name in fm-move ak47-state orcad-1 systemd-private-x snap-foo \
              .X11-unix .ICE-unix .font-unix .Test-unix .XIM-unix \
              cli-proxy-api.sock forwarder.token my-router.sh; do
    [ -e "$AK47_TMP_ROOT/$name" ] || fail "tick removed the protected path $name"
  done
  pass "tick refuses every named protected path"
}

test_refuses_a_symlink_that_points_at_a_protected_path() {
  reset_tree
  # A symlink whose NAME is innocuous but whose target is protected. The
  # classifier canonicalises a symlink before deciding, so this must survive.
  mkdir -p "$AK47_TMP_ROOT/ak47-real"
  ln -s "$AK47_TMP_ROOT/ak47-real" "$AK47_TMP_ROOT/tmpc005nnn_"
  age "$AK47_TMP_ROOT/tmpc005nnn_"
  "$TICK" --apply >/dev/null 2>&1 || fail "tick exited non-zero"
  [ -L "$AK47_TMP_ROOT/tmpc005nnn_" ] \
    || fail "tick removed a symlink pointing at a protected path"
  pass "tick refuses a symlink that points at a protected path"
}

test_refuses_a_young_leak() {
  reset_tree
  # Age gate at one day, and the candidate is one minute old: a suite that is
  # still running must never be touched.
  sed -i 's/^tmp_mktemp_min=.*/tmp_mktemp_min=1440/' "$AK47_CONFIG/devops.conf"
  local d=$AK47_TMP_ROOT/tmpd006ooo_
  mkdir -p "$d"
  "$TICK" --apply >/dev/null 2>&1 || fail "tick exited non-zero"
  [ -d "$d" ] || fail "tick removed a leak younger than its age gate"
  pass "tick refuses a leak younger than its age gate"
}

# --- the actions ----------------------------------------------------------------

test_quarantines_a_leaked_default_temp_dir() {
  reset_tree
  local d=$AK47_TMP_ROOT/tmpe007ppp_
  mkdir -p "$d"; age "$d"
  "$TICK" --apply >/dev/null 2>&1 || fail "tick exited non-zero"
  [ ! -e "$d" ] || fail "tick left a leaked default temp dir in place"
  # Quarantine, not deletion: the entry must still exist under the state dir.
  local found
  found=$(find "$AK47_STATE/quarantine" -maxdepth 2 -name 'tmpe007ppp_' -print -quit 2>/dev/null)
  [ -n "$found" ] || fail "tick deleted the entry instead of quarantining it"
  pass "tick quarantines a leaked default temp dir, and the revert path exists"
}

test_quarantines_a_leaked_named_producer_dir() {
  reset_tree
  local name
  for name in uvn-abc123 wc-1 irc-2 merge-outcome-x twin-req-9 \
              puppeteer_dev_chrome_profile-zz rmtc-1 restore-test-1 csv-1; do
    mkdir -p "$AK47_TMP_ROOT/$name"; age "$AK47_TMP_ROOT/$name"
  done
  "$TICK" --apply >/dev/null 2>&1 || fail "tick exited non-zero"
  for name in uvn-abc123 wc-1 irc-2 merge-outcome-x twin-req-9 \
              puppeteer_dev_chrome_profile-zz rmtc-1 restore-test-1 csv-1; do
    [ ! -e "$AK47_TMP_ROOT/$name" ] || fail "tick left the leaked producer dir $name"
  done
  pass "tick quarantines every named producer prefix"
}

test_quarantined_entry_keeps_its_full_revert_window() {
  reset_tree
  # mv preserves mtime, so an entry that was already old when it was moved into
  # quarantine must still get its full window measured from the move day.
  local day entry
  day=$(date -u +%Y%m%d)
  entry="$AK47_STATE/quarantine/$day/tmpold001aaa_"
  mkdir -p "$entry"
  touch -d '30 days ago' "$entry"
  "$TICK" --apply >/dev/null 2>&1 || fail "tick exited non-zero"
  [ -d "$entry" ] \
    || fail "tick deleted a just-quarantined entry because its mtime was old"
  pass "a quarantined entry keeps its full revert window regardless of its mtime"
}

test_expires_an_entry_after_its_quarantine_window() {
  reset_tree
  local day entry
  day=$(date -u -d '8 days ago' +%Y%m%d)
  entry="$AK47_STATE/quarantine/$day/tmpold002bbb_"
  mkdir -p "$entry"
  "$TICK" --apply >/dev/null 2>&1 || fail "tick exited non-zero"
  [ ! -e "$entry" ] \
    || fail "tick kept an entry past its quarantine window"
  pass "an entry is deleted once its dated quarantine directory is past the window"
}

test_dry_run_changes_nothing() {
  reset_tree
  local d=$AK47_TMP_ROOT/tmpf008qqq_
  mkdir -p "$d"; age "$d"
  "$TICK" --dry-run >/dev/null 2>&1 || fail "dry run exited non-zero"
  [ -d "$d" ] || fail "dry run removed an entry"
  [ ! -d "$AK47_STATE/quarantine" ] || fail "dry run created a quarantine directory"
  pass "dry run changes nothing"
}

test_stops_quarantining_once_under_the_entry_ceiling() {
  reset_tree
  # Ceiling of 2 entries, and the tree already has 2: the tick must stop, because
  # tmp_max_entries is the point at which the tick stops working, not a per-run
  # move budget.
  sed -i 's/^tmp_max_entries=.*/tmp_max_entries=2/' "$AK47_CONFIG/devops.conf"
  local d=$AK47_TMP_ROOT/tmpg009rrr_
  mkdir -p "$d" "$AK47_TMP_ROOT/tmph010sss_"
  age "$d"; age "$AK47_TMP_ROOT/tmph010sss_"
  "$TICK" --apply >/dev/null 2>&1 || fail "tick exited non-zero"
  [ -d "$d" ] || fail "tick kept quarantining past its entry ceiling"
  pass "tick stops quarantining once the tree is under its entry ceiling"
}

test_stops_as_soon_as_the_live_tree_crosses_the_ceiling() {
  reset_tree
  # Three candidates, a ceiling of 2, and a move budget far above the number of
  # candidates. The tick must stop after the first move brings the live tree to
  # the ceiling, not spend the whole per-run budget.
  sed -i 's/^tmp_max_entries=.*/tmp_max_entries=2/' "$AK47_CONFIG/devops.conf"
  local d
  for d in tmpi011aaa_ tmpj012bbb_ tmpk013ccc_; do
    mkdir -p "$AK47_TMP_ROOT/$d"
    age "$AK47_TMP_ROOT/$d"
  done
  "$TICK" --apply >/dev/null 2>&1 || fail "tick exited non-zero"
  local n
  n=$(find "$AK47_STATE/quarantine" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | wc -l)
  [ "$n" -eq 1 ] || fail "tick moved $n entries instead of stopping at the ceiling"
  pass "tick stops as soon as the live tree crosses the entry ceiling"
}

test_quarantines_a_same_day_name_collision_without_nesting() {
  reset_tree
  local d=$AK47_TMP_ROOT/tmpl014ddd_
  mkdir -p "$d"; age "$d"
  "$TICK" --apply >/dev/null 2>&1 || fail "first tick exited non-zero"
  # A producer recreates the same name on the same UTC day.
  mkdir -p "$d"; age "$d"
  "$TICK" --apply >/dev/null 2>&1 || fail "second tick exited non-zero"
  local day
  day=$(find "$AK47_STATE/quarantine" -mindepth 1 -maxdepth 1 -type d | head -n 1)
  [ -n "$day" ] || fail "tick did not quarantine either entry"
  [ -d "$day/tmpl014ddd_" ] || fail "first quarantined entry is missing"
  [ -d "$day/tmpl014ddd_.1" ] || fail "second quarantined entry did not get a unique name"
  [ ! -e "$day/tmpl014ddd_/tmpl014ddd_" ] || fail "second entry was nested inside the first"
  pass "a same-day name collision is quarantined under a unique name, not nested"
}

# --- the log --------------------------------------------------------------------

test_writes_exactly_one_line_per_run() {
  reset_tree
  "$TICK" --apply >/dev/null 2>&1 || fail "first run exited non-zero"
  "$TICK" --apply >/dev/null 2>&1 || fail "second run exited non-zero"
  local n
  n=$(wc -l <"$AK47_STATE/devops.log")
  [ "$n" -eq 2 ] || fail "expected 2 log lines after 2 runs, got $n"
  pass "the tick writes exactly one log line per run, so silence is provable"
}

test_the_log_line_carries_the_verdict() {
  reset_tree
  "$TICK" --apply >/dev/null 2>&1 || fail "tick exited non-zero"
  local line
  line=$(tail -n 1 "$AK47_STATE/devops.log")
  local field
  for field in tick mode= tmp_before= tmp_after= moved= deleted= busy= \
               protected= failures= actions= loop_gap= classes= breaches= top=; do
    case "$line" in
      *"$field"*) : ;;
      *) fail "log line is missing $field: $line" ;;
    esac
  done
  pass "the log line carries every field a reader needs without a second read"
}

test_writes_a_numeric_sample_for_the_weekly_review() {
  reset_tree
  "$TICK" --apply >/dev/null 2>&1 || fail "tick exited non-zero"
  [ -s "$AK47_STATE/samples.log" ] || fail "tick wrote no samples.log line"
  local line first
  line=$(tail -n 1 "$AK47_STATE/samples.log")
  first=${line%% *}
  case "$first" in
    ''|*[!0-9]*) fail "sample line does not start with an epoch: $line" ;;
  esac
  case "$line" in
    *load15=*) : ;;
    *) fail "sample line is missing load15: $line" ;;
  esac
  case "$line" in
    *tmp_entries=*) : ;;
    *) fail "sample line is missing tmp_entries: $line" ;;
  esac
  # Every metric must contribute exactly one number. A sampler that prints two
  # lines (pgrep -c prints 0 AND exits 1 on no match) splits the sample across
  # two lines and the review silently reads a bare "0" as the whole sample.
  local n
  n=$(wc -l <"$AK47_STATE/samples.log")
  [ "$n" -eq 1 ] || fail "one run wrote $n sample lines; expected exactly 1"
  case "$line" in
    *agent_count=*) : ;;
    *) fail "sample line is missing agent_count: $line" ;;
  esac
  local agents
  agents=$(printf '%s\n' "$line" | sed -n 's/.*agent_count=\([^ ]*\).*/\1/p')
  case "$agents" in
    ''|*[!0-9]*) fail "agent_count is not a single number: '$agents' in $line" ;;
    *) : ;;
  esac
  pass "the tick writes the numeric sample the weekly review reads"
}

test_reports_its_own_loop_gap() {
  reset_tree
  # A previous run 4 hours ago, against a 300s interval: the tick must notice
  # that its own loop stopped, because a loop that dies silently is worse than
  # no loop.
  # The log line's first field is the ISO timestamp ak47_log writes, so the
  # fixture has to use the same spelling the reader parses.
  printf '%s tick mode=apply tmp_before=0 tmp_after=0\n' \
    "$(date -u -d '4 hours ago' +%Y-%m-%dT%H:%M:%SZ)" >"$AK47_STATE/devops.log"
  "$TICK" --apply >/dev/null 2>&1 || fail "tick exited non-zero"
  local line
  line=$(tail -n 1 "$AK47_STATE/devops.log")
  case "$line" in
    *loop_gap=1[0-9][0-9][0-9][0-9]s*) : ;;
    *) fail "tick did not report a four-hour loop gap: $line" ;;
  esac
  grep -q 'loop-gap' "$AK47_STATE/findings.log" 2>/dev/null \
    || fail "tick reported a loop gap on its log line but filed no finding"
  pass "the tick notices and files its own loop gap"
}

test_refuses_a_malformed_config() {
  reset_tree
  sed -i 's/^tmp_mktemp_min=.*/tmp_mktemp_min=soon/' "$AK47_CONFIG/devops.conf"
  if "$TICK" --apply >/dev/null 2>&1; then
    fail "tick accepted a non-numeric config value"
  fi
  pass "tick refuses a malformed config value instead of guessing"
}

# --- the fat-process escalation and the finding delivery ----------------------

test_escalates_an_ignored_sigterm_to_sigkill() {
  reset_tree
  sed -i 's/^fat_process=.*/fat_process=1/' "$AK47_CONFIG/devops.conf"
  sleep 60 &
  local p=$!
  # A record from ten minutes ago: the tick that sent SIGTERM is long gone, so
  # only the durable clock can escalate.
  printf '%s %s\n' "$p" "$(( $(date +%s) - 600 ))" >"$AK47_STATE/fat.term"
  "$TICK" --apply >/dev/null 2>&1 || fail "tick exited non-zero"
  sleep 0.2
  if kill -0 "$p" 2>/dev/null; then
    kill -KILL "$p" 2>/dev/null
    fail "tick did not SIGKILL a pid that ignored SIGTERM for ten minutes"
  fi
  grep -q 'SIGKILL' "$AK47_STATE/reap.log" 2>/dev/null \
    || fail "the escalation was not logged with its revert"
  [ -s "$AK47_STATE/fat.term" ] && fail "the fat.term record survived the kill"
  pass "tick escalates an ignored SIGTERM to SIGKILL across runs"
}

test_a_dry_run_does_not_consume_the_escalation() {
  reset_tree
  sed -i 's/^fat_process=.*/fat_process=1/' "$AK47_CONFIG/devops.conf"
  sleep 60 &
  local p=$! stamp
  stamp=$(( $(date +%s) - 600 ))
  printf '%s %s\n' "$p" "$stamp" >"$AK47_STATE/fat.term"
  "$TICK" --dry-run >/dev/null 2>&1 || fail "tick exited non-zero"
  kill -0 "$p" 2>/dev/null || fail "a dry run killed a process"
  grep -q "^$p $stamp$" "$AK47_STATE/fat.term" 2>/dev/null \
    || fail "a dry run consumed the escalation record, so the next real tick would miss it"
  grep -q 'fat-process' "$AK47_STATE/findings.log" 2>/dev/null \
    || fail "a dry run did not file a finding for the escalation it would perform"
  kill -KILL "$p" 2>/dev/null
  pass "a dry run neither kills nor consumes the escalation record"
}

test_commits_a_finding_key_only_after_delivery() {
  reset_tree
  # A failed inbox send must leave the dedupe key uncommitted, or the finding is
  # silenced for six hours. The fake fm-inbox.sh is the only delivery path.
  printf '#!/usr/bin/env bash\nexit 1\n' >"$FM_HOME/bin/fm-inbox.sh"
  chmod +x "$FM_HOME/bin/fm-inbox.sh"
  printf '%s tick mode=apply tmp_before=0 tmp_after=0\n' \
    "$(date -u -d '4 hours ago' +%Y-%m-%dT%H:%M:%SZ)" >"$AK47_STATE/devops.log"
  "$TICK" --apply >/dev/null 2>&1 || fail "tick exited non-zero"
  [ -f "$AK47_STATE/keys/loop-gap" ] \
    && fail "a finding's dedupe key was committed before its note was delivered"
  grep -q 'DELIVERY-FAILED' "$AK47_STATE/findings.log" 2>/dev/null \
    || fail "a failed delivery was not recorded"
  pass "a failed delivery does not commit the finding's dedupe key"
}

test_delivery_commits_the_key_so_the_next_tick_is_quiet() {
  reset_tree
  printf '#!/usr/bin/env bash\nexit 0\n' >"$FM_HOME/bin/fm-inbox.sh"
  chmod +x "$FM_HOME/bin/fm-inbox.sh"
  printf '%s tick mode=apply tmp_before=0 tmp_after=0\n' \
    "$(date -u -d '4 hours ago' +%Y-%m-%dT%H:%M:%SZ)" >"$AK47_STATE/devops.log"
  "$TICK" --apply >/dev/null 2>&1 || fail "tick exited non-zero"
  [ -f "$AK47_STATE/keys/loop-gap" ] \
    || fail "a delivered finding did not commit its dedupe key"
  pass "a delivered finding commits its key so it is not re-sent"
}

test_reports_a_dry_run_that_outlived_its_24_hours() {
  reset_tree
  # The first tick line is 25 hours old, and both acting classes are still
  # report-only: the tick must say so without arming itself.
  printf '%s tick mode=apply tmp_before=0 tmp_after=0\n' \
    "$(date -u -d '25 hours ago' +%Y-%m-%dT%H:%M:%SZ)" >"$AK47_STATE/devops.log"
  "$TICK" --apply >/dev/null 2>&1 || fail "tick exited non-zero"
  grep -q 'swap-unarmed' "$AK47_STATE/findings.log" 2>/dev/null \
    || fail "the tick did not flag a report-only class past its 24 h dry run"
  grep -q 'fat-unarmed' "$AK47_STATE/findings.log" 2>/dev/null \
    || fail "the tick did not flag fat-process past its 24 h dry run"
  pass "the tick flags a report-only class that outlived its dry run"
}

test_refuses_a_directory_a_live_process_is_sitting_in
test_refuses_a_directory_a_live_process_has_a_file_open_in
test_refuses_a_live_tasks_scratch_root
test_quarantines_an_orphaned_task_scratch_root
test_refuses_every_named_protected_path
test_refuses_a_symlink_that_points_at_a_protected_path
test_refuses_a_young_leak
test_quarantines_a_leaked_default_temp_dir
test_quarantines_a_leaked_named_producer_dir
test_quarantined_entry_keeps_its_full_revert_window
test_expires_an_entry_after_its_quarantine_window
test_dry_run_changes_nothing
test_stops_quarantining_once_under_the_entry_ceiling
test_stops_as_soon_as_the_live_tree_crosses_the_ceiling
test_quarantines_a_same_day_name_collision_without_nesting
test_writes_exactly_one_line_per_run
test_the_log_line_carries_the_verdict
test_writes_a_numeric_sample_for_the_weekly_review
test_reports_its_own_loop_gap
test_refuses_a_malformed_config
test_escalates_an_ignored_sigterm_to_sigkill
test_a_dry_run_does_not_consume_the_escalation
test_commits_a_finding_key_only_after_delivery
test_delivery_commits_the_key_so_the_next_tick_is_quiet
test_reports_a_dry_run_that_outlived_its_24_hours
test_a_size_walk_that_overruns_does_not_hang_the_tick
test_an_unmeasurable_tree_is_a_finding_not_silence
test_a_failed_size_walk_is_retried_once_its_window_elapses
test_expiry_is_bounded_per_run_and_says_what_is_left
test_expiry_does_not_run_lsof_per_entry
test_a_finding_is_delivered_to_the_real_inbox
test_swap_is_restored_even_when_the_reclaim_fails
test_swap_privilege_probes_the_granted_command
test_an_unprivileged_tick_says_so_instead_of_failing_to_swap
test_a_privileged_tick_rings_the_reclaim_and_does_not_swap_inline

# --- one finding per episode, not one per tick ------------------------------------
# 2026-11-15: the health beat pruned every key in $AK47_STATE/keys that was not
# one of its own, so the tick's tmp-gb-stale key was deleted every five minutes
# and the finding re-paged on every tick - 59 notes in a day. The tick now owns
# its episode: it reports once, stays quiet while the key stands, and clears the
# key when the tree is measurable again so the next episode reports immediately.

test_a_stale_size_walk_is_reported_once_per_episode() {
  reset_tree
  # A successful delivery is what commits the episode key; without it the tick
  # correctly re-files every run. Do not depend on an earlier test's fake inbox.
  printf '#!/usr/bin/env bash\nexit 0\n' >"$FM_HOME/bin/fm-inbox.sh"
  chmod +x "$FM_HOME/bin/fm-inbox.sh"
  local slow=$SANDBOX/slowbin-ep
  mkdir -p "$slow"
  printf '#!/bin/sh\nexec sleep 300\n' >"$slow/du"
  chmod +x "$slow/du"
  mkdir -p "$AK47_TMP_ROOT/uvn-old"; head -c 200000 /dev/zero >"$AK47_TMP_ROOT/uvn-old/blob"
  # A real measurement from long ago, and a walk that no longer finishes.
  printf 'tmp_gb\t%s\t999\n' $(( $(date +%s) - 100000 )) >"$AK47_STATE/sample.cache"
  printf 'tmp_gb_ok\t%s\t%s\n' $(( $(date +%s) - 100000 )) $(( $(date +%s) - 100000 )) >>"$AK47_STATE/sample.cache"
  PATH="$slow:$PATH" AK47_DU_BUDGET=2 AK47_DU_TTL=60 AK47_DU_RETRY=0 "$TICK" --apply >/dev/null 2>&1 \
    || fail "the first stale tick exited non-zero"
  PATH="$slow:$PATH" AK47_DU_BUDGET=2 AK47_DU_TTL=60 AK47_DU_RETRY=0 "$TICK" --apply >/dev/null 2>&1 \
    || fail "the second stale tick exited non-zero"
  local n; n=$(grep -c tmp-gb-stale "$AK47_STATE/findings.log" 2>/dev/null || echo 0)
  [ "$n" -eq 1 ] || fail "a stale size walk was reported $n times in two ticks; it must report once per episode"
  pass "a stale size walk is reported once per episode, not once per tick"
}

test_a_measurable_tree_ends_the_episode() {
  reset_tree
  printf '#!/usr/bin/env bash\nexit 0\n' >"$FM_HOME/bin/fm-inbox.sh"
  chmod +x "$FM_HOME/bin/fm-inbox.sh"
  local slow=$SANDBOX/slowbin-ep2
  mkdir -p "$slow"
  printf '#!/bin/sh\nexec sleep 300\n' >"$slow/du"
  chmod +x "$slow/du"
  mkdir -p "$AK47_TMP_ROOT/uvn-old"; head -c 200000 /dev/zero >"$AK47_TMP_ROOT/uvn-old/blob"
  printf 'tmp_gb\t%s\t999\n' $(( $(date +%s) - 100000 )) >"$AK47_STATE/sample.cache"
  printf 'tmp_gb_ok\t%s\t%s\n' $(( $(date +%s) - 100000 )) $(( $(date +%s) - 100000 )) >>"$AK47_STATE/sample.cache"
  PATH="$slow:$PATH" AK47_DU_BUDGET=2 AK47_DU_TTL=60 AK47_DU_RETRY=0 "$TICK" --apply >/dev/null 2>&1 \
    || fail "the stale tick exited non-zero"
  [ -f "$AK47_STATE/keys/tmp-gb-stale" ] || fail "the stale episode left no key, so it would re-page every tick"
  # The tree is measurable again: a real walk stamps tmp_gb_ok and the key goes.
  printf 'tmp_gb\t%s\t5\n' "$(date +%s)" >"$AK47_STATE/sample.cache"
  printf 'tmp_gb_ok\t%s\t%s\n' "$(date +%s)" "$(date +%s)" >>"$AK47_STATE/sample.cache"
  AK47_DU_TTL=60 "$TICK" --apply >/dev/null 2>&1 || fail "the healthy tick exited non-zero"
  [ ! -f "$AK47_STATE/keys/tmp-gb-stale" ] \
    || fail "the episode key survived a measurable tree; the next episode would be silenced for six hours"
  pass "a measurable tree ends the episode so the next one reports at once"
}

# --- the walk is bounded and says how much of the tree it covered -----------------
# A single `du` over the whole tree is all-or-nothing: on a tree too big to finish
# inside the budget it yields nothing, so the number never refreshes. The walk now
# measures top-level entries in batches and records its coverage.

test_a_partial_size_walk_records_its_coverage() {
  reset_tree
  local i
  # More entries than one batch (25), so the budget can only reach the first.
  for i in $(seq 1 30); do mkdir -p "$AK47_TMP_ROOT/d$i"; head -c 20000 /dev/zero >"$AK47_TMP_ROOT/d$i/blob"; done
  local slow=$SANDBOX/slowbin-part
  mkdir -p "$slow"
  # The whole-tree walk never finishes; the batched walk works but costs a
  # second per batch, so a 1 s budget can only reach the first batch.
  printf '#!/bin/sh\nif [ $# -gt 1 ]; then sleep 1; exec /usr/bin/du "$@"; fi\nexec sleep 300\n' >"$slow/du"
  chmod +x "$slow/du"
  PATH="$slow:$PATH" AK47_DU_BUDGET=1 AK47_DU_TTL=0 bash -c \
    '. "$1/ak47/lib/common.sh"; ak47_tmp_gb >/dev/null' _ "$ROOT" \
    || fail "the bounded walk exited non-zero"
  local cov; cov=$(awk -F'\t' '$1=="tmp_gb_partial"{print $3}' "$AK47_STATE/sample.cache" 2>/dev/null)
  [ -n "$cov" ] || fail "a partial walk recorded no coverage; a reader cannot tell a partial number from a whole one"
  case "$cov" in
    [0-9]*/[0-9]*) ;;
    *) fail "the coverage record is not <measured>/<present>: $cov" ;;
  esac
  pass "a partial size walk records how much of the tree it covered"
}

test_a_partial_walk_does_not_claim_the_tree_was_measured() {
  reset_tree
  local i
  # More entries than one batch (25), so the budget can only reach the first.
  for i in $(seq 1 30); do mkdir -p "$AK47_TMP_ROOT/d$i"; head -c 20000 /dev/zero >"$AK47_TMP_ROOT/d$i/blob"; done
  local slow=$SANDBOX/slowbin-part2
  mkdir -p "$slow"
  printf '#!/bin/sh\nif [ $# -gt 1 ]; then sleep 1; exec /usr/bin/du "$@"; fi\nexec sleep 300\n' >"$slow/du"
  chmod +x "$slow/du"
  PATH="$slow:$PATH" AK47_DU_BUDGET=1 AK47_DU_TTL=0 bash -c \
    '. "$1/ak47/lib/common.sh"; ak47_tmp_gb >/dev/null' _ "$ROOT" \
    || fail "the bounded walk exited non-zero"
  local ok; ok=$(awk -F'\t' '$1=="tmp_gb_ok"{print $3}' "$AK47_STATE/sample.cache" 2>/dev/null)
  [ -z "$ok" ] || fail "a partial walk stamped tmp_gb_ok, so the staleness finding would go quiet on a number that covers part of the tree"
  pass "a partial walk does not claim the tree was measured"
}

# --- the health beat must not clear the tick's keys -------------------------------
# The two producers share $AK47_STATE/keys. The beat prunes keys for findings that
# went away, and it only knows its own findings, so pruning the whole directory
# deleted the tick's keys and made every tick re-page.

test_the_health_beat_prunes_only_its_own_keys() {
  local h=$ROOT/ak47/hdevops/ansible/playbooks/templates/ak47-health.sh
  local home=$SANDBOX/health-home bin=$SANDBOX/health-bin sd
  rm -rf "$home" "$bin"
  mkdir -p "$home/.local/state/ak47" "$home/fmhome/bin" "$home/fmhome/state" "$bin"
  sd=$home/.local/state/ak47
  cat >"$home/fmhome/bin/fm-inbox.sh" <<'SH'
#!/bin/sh
exit 0
SH
  chmod +x "$home/fmhome/bin/fm-inbox.sh"
  # Keep the beat off the real box: no Wi-Fi, sensors, failed units, agents, or
  # /tmp walk. A fresh state directory has no devops.log, so devops-absent is a
  # deterministic finding that must be delivered and keyed.
  cat >"$bin/du" <<'SH'
#!/bin/sh
printf '1\t/tmp\n'
SH
  cat >"$bin/sudo" <<'SH'
#!/bin/sh
exit 1
SH
  cat >"$bin/ip" <<'SH'
#!/bin/sh
exit 0
SH
  cat >"$bin/sensors" <<'SH'
#!/bin/sh
exit 0
SH
  cat >"$bin/systemctl" <<'SH'
#!/bin/sh
exit 0
SH
  cat >"$bin/pgrep" <<'SH'
#!/bin/sh
case "$*" in *-c*) echo 0 ;; esac
exit 0
SH
  cat >"$bin/notify-send" <<'SH'
#!/bin/sh
exit 0
SH
  chmod +x "$bin"/*
  mkdir -p "$sd/keys"
  printf 'tick\n' >"$sd/keys/tmp-gb-stale"
  HOME="$home" FM_HOME="$home/fmhome" AK47_USER_SLICE="$home/no-slice" \
    PATH="$bin:$PATH" bash "$h" >/dev/null 2>&1 || fail "the health beat exited non-zero"
  [ -f "$sd/keys/health/devops-absent" ] \
    || fail "a delivered finding did not commit its key under keys/health"
  printf 'old\n' >"$sd/keys/health/old-finding"
  HOME="$home" FM_HOME="$home/fmhome" AK47_USER_SLICE="$home/no-slice" \
    PATH="$bin:$PATH" bash "$h" >/dev/null 2>&1 || fail "the health beat exited non-zero"
  [ -e "$sd/keys/health/old-finding" ] \
    && fail "the health beat did not prune a stale key of its own"
  [ -e "$sd/keys/tmp-gb-stale" ] \
    || fail "the health beat pruned the tick's key"
  [ -e "$sd/keys/health/devops-absent" ] \
    || fail "the health beat pruned the key for a finding it still reports"
  pass "the health beat prunes only its own keys, so the tick keeps its episodes"
}
test_a_stale_size_walk_is_reported_once_per_episode
test_a_measurable_tree_ends_the_episode
test_a_partial_size_walk_records_its_coverage
test_a_partial_walk_does_not_claim_the_tree_was_measured
test_the_health_beat_prunes_only_its_own_keys
