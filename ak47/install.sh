#!/usr/bin/env bash
# ak47/install.sh - put the hygiene system on this box, and say how to take it off.
#
# Installs two user timers (the 5-minute tick and the Monday review), seeds the
# operator config if it is absent, records the first census baseline, and runs
# one tick so the log is provably alive before the script exits.
#
# Idempotent: running it twice changes nothing the second time.
# Reversible: --uninstall removes the units and leaves every log, every
# quarantine directory, and every config file exactly where it is.
#
# Usage: install.sh [--dry-run] [--uninstall] [--no-start]
#   --dry-run    print every action, change nothing
#   --uninstall  stop and remove the units; keep all state
#   --no-start   install and enable, but do not start the timers now
#
# Exit: 0 installed, 1 a step failed, 2 bad usage.
set -u

AK47_ROOT=${AK47_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)}
# shellcheck source=lib/common.sh
. "$AK47_ROOT/lib/common.sh"

UNIT_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
DRY=0; UNINSTALL=0; START=1
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --no-start) START=0; shift ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "install.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done

run() {
  if [ "$DRY" = 1 ]; then
    printf 'would: %s\n' "$*"
  else
    printf 'run: %s\n' "$*"
    "$@" || { echo "install.sh: FAILED: $*" >&2; exit 1; }
  fi
}

UNITS="ak47-devops.service ak47-devops.timer ak47-devops-weekly.service ak47-devops-weekly.timer"

# ---- uninstall -----------------------------------------------------------------
if [ "$UNINSTALL" = 1 ]; then
  echo "== removing the ak47 hygiene timers (state is kept) =="
  for u in $UNITS; do
    run systemctl --user disable --now "$u" 2>/dev/null || true
  done
  for u in $UNITS; do
    [ -f "$UNIT_DIR/$u" ] && run rm -f "$UNIT_DIR/$u"
  done
  run systemctl --user daemon-reload
  echo
  echo "Removed. Kept, deliberately:"
  echo "  $AK47_STATE   logs, quarantine, findings, baselines"
  echo "  $AK47_CONFIG  devops.conf"
  echo "  $AK47_CACHE   the cached du sample"
  echo "Delete those by hand if you want the history gone too."
  exit 0
fi

# ---- preflight -----------------------------------------------------------------
echo "== ak47 hygiene install =="
echo "repo:  $AK47_ROOT"
echo "state: $AK47_STATE"
echo "units: $UNIT_DIR"
echo

for f in tick.sh status.sh census.sh weekly-review.sh guards/guard-producers.sh; do
  [ -x "$AK47_ROOT/$f" ] || { echo "install.sh: $f is missing or not executable" >&2; exit 1; }
done
command -v systemctl >/dev/null || { echo "install.sh: no systemctl on this box" >&2; exit 1; }
systemctl --user show-environment >/dev/null 2>&1 \
  || { echo "install.sh: no user systemd session; log in as the owning user, not via su" >&2; exit 1; }

# ---- directories and config ----------------------------------------------------
run mkdir -p "$AK47_STATE" "$AK47_CACHE" "$AK47_CONFIG" "$UNIT_DIR"
if [ ! -f "$AK47_CONFIG/devops.conf" ]; then
  if [ "$DRY" = 1 ]; then
    echo "would: seed $AK47_CONFIG/devops.conf"
  else
    cat >"$AK47_CONFIG/devops.conf" <<'CONF'
# ak47/devops.conf - operator knobs for the hygiene tick.
#
# Every key is optional; the tick falls back to the default shown. Values are
# whole numbers. This file is parsed, never sourced.
#
# How long a leaked default temp directory must sit before it is quarantined.
# 1440 (one day) is long enough that a suite still running is never touched, and
# short enough that a leak is gone before it becomes a million-entry problem.
tmp_mktemp_min=1440
# The same, for a named producer prefix (uvn-, wc-, irc-, ...).
tmp_producer_min=1440
# A /tmp/fm-<id> scratch root with no live task record. 10080 (one week) is
# generous on purpose: a task record can be missing for a while during recovery.
orphan_min=10080
# How long a quarantined entry is kept before it is deleted for good.
quarantine_days=7
# Stop quarantining once /tmp is back under this many entries. 5000 is well
# below the 200,000 budget ceiling: the tick should finish the job, not nibble.
tmp_max_entries=5000
# The most entries one run may move. A per-run budget, separate from the
# stop-working gate above, so a single tick cannot spend its whole timeout
# moving a backlog and then fail to write its log line.
tmp_max_moves=2000
# Report-only classes. Set to 1 to arm them; each one is documented in README.md
# and each one is reversible.
swap_pressure=0
fat_process=0
fat_process_gb=3
fat_process_min=10
# The timer's period, so the tick can notice its own loop has stopped.
interval_seconds=300
CONF
    echo "seeded: $AK47_CONFIG/devops.conf"
  fi
fi

# ---- units ---------------------------------------------------------------------
for u in $UNITS; do
  src=$AK47_ROOT/units/$u
  [ -f "$src" ] || { echo "install.sh: missing unit $src" >&2; exit 1; }
  if [ "$DRY" = 1 ]; then
    echo "would: install $UNIT_DIR/$u"
  else
    install -m 0644 "$src" "$UNIT_DIR/$u"
    echo "installed: $UNIT_DIR/$u"
  fi
done

run systemctl --user daemon-reload

# ---- first run, before the timer is trusted ------------------------------------
# A timer that is enabled but whose unit cannot run is worse than no timer: it
# looks installed. Run the tick once by hand and refuse to enable on failure.
echo
echo "== first tick (proves the unit can run before the timer is trusted) =="
if [ "$DRY" = 1 ]; then
  echo "would: $AK47_ROOT/tick.sh --apply"
else
  if ! "$AK47_ROOT/tick.sh" --apply; then
    echo "install.sh: the first tick failed; the timer is NOT enabled" >&2
    echo "install.sh: inspect $AK47_STATE/devops.log and re-run after fixing" >&2
    exit 1
  fi
  echo "first tick ok: $(tail -n 1 "$AK47_STATE/devops.log" 2>/dev/null)"
fi

# ---- census baseline -----------------------------------------------------------
# Recorded once, here, so the guard's dynamic check has a reference that the
# check itself never moves.
echo
echo "== census baseline =="
if [ "$DRY" = 1 ]; then
  echo "would: $AK47_ROOT/census.sh --write-baseline"
else
  "$AK47_ROOT/census.sh" --write-baseline || echo "install.sh: baseline not written (census failed); the dynamic guard will skip"
fi

# ---- enable --------------------------------------------------------------------
echo
echo "== enabling =="
for u in ak47-devops.timer ak47-devops-weekly.timer; do
  run systemctl --user enable "$u"
  [ "$START" = 1 ] && run systemctl --user start "$u"
done

echo
echo "== done =="
if [ "$DRY" = 1 ]; then
  echo "Dry run: nothing was changed."
  exit 0
fi
systemctl --user list-timers 'ak47-devops*' --no-pager 2>/dev/null || true
echo
echo "Read the budget:   $AK47_ROOT/status.sh --print"
echo "Read the log:      tail -n 20 $AK47_STATE/devops.log"
echo "Check the guards:  $AK47_ROOT/guards/guard-producers.sh"
echo "Take it off:       $AK47_ROOT/install.sh --uninstall"
