#!/usr/bin/env bash
# Behavior test for this add-on's fm-dashboard.sh: when one home's backlog
# cannot be read, the fleet's Ready and queue numbers must still show the counts
# of the homes that were read, marked as a lower bound, and must name the unread
# home. Only when no home can be read do they fall back to unknown.
#
# The dashboard runs its readers (fm-tasks-axi.sh, fm-flow.sh, ...) from the
# directory that holds it, so this builds a scratch copy of a fork tree's bin/
# with this add-on's fm-dashboard.sh swapped in and drives the real script
# there. Skipped when that tree or a required tool is absent. FM_FORK points at
# the fork tree (default ~/firstmate).
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ADDON=$(dirname "$HERE")
FORK=${FM_FORK:-$HOME/firstmate}
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }
[ -f "$FORK/bin/fm-tasks-axi.sh" ] || { echo "skip: no fork tree at $FORK (set FM_FORK)"; exit 0; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-dashboard-partial.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

# A scratch bin/ copy of the fork's readers with this add-on's script and app
# swapped in, so the script under test is the one just changed. FM_DASHBOARD_SRC
# points the swap at another fm-dashboard.sh (for example the pre-fix one) to
# reproduce the old blanking behavior.
mkdir -p "$TMP/bin"
cp -R "$FORK/bin/." "$TMP/bin/" || { echo "skip: cannot copy $FORK/bin"; exit 0; }
rm -rf "$TMP/bin/fm-dashboard"
cp "${FM_DASHBOARD_SRC:-$ADDON/fm-dashboard.sh}" "$TMP/bin/fm-dashboard.sh"
cp "$ADDON/task_rows.py" "$TMP/bin/task_rows.py"
cp -R "$ADDON/fm-dashboard" "$TMP/bin/fm-dashboard"
DASH="$TMP/bin/fm-dashboard.sh"
# Fast, failing stubs for the unrelated readers: this case is about the backlog.
for r in fm-flow fm-model-stats fm-skill-stats; do printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/$r.sh"; done

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

page_text() {  # <page>: the visible text, one space between words
  python3 - "$1" <<'PY'
import html, re, sys
s = open(sys.argv[1]).read()
s = re.sub(r'<(style|title)>.*?</\1>', ' ', s, flags=re.S)
print(re.sub(r'\s+', ' ', html.unescape(re.sub(r'<[^>]+>', ' ', s))))
PY
}
has() {  # <page> <want>...
  local page=$1 text want
  shift
  text=$(page_text "$page")
  for want in "$@"; do
    case "$text" in *"$want"*) ;; *) fail "$(basename "$page") lacks '$want': $text" ;; esac
  done
}

# The fleet: Main readable, lead zephyrine (unreadable in the first phase), and
# a parked beta that no total counts.
make_fixture() {  # <root>
  local fix=$1 z=$1/mates/zephyrine today
  today=$(date +%F)
  mkdir -p "$fix/data" "$fix/state" "$fix/config" "$z/data" "$z/state" "$fix/stubs"
  printf -- '- zephyrine - domain (home: %s; scope: work; projects: alpha; added 2026-07-11)\n' "$z" > "$fix/data/secondmates.md"
  printf '3\n' > "$fix/config/lane-target"
  printf 'main 6\n' > "$fix/config/lane-caps"
  printf 'beta  # parked by the captain\n' > "$fix/config/parked-homes"
  cat > "$fix/data/backlog.md" <<EOF
## Queued
- [ ] m-ready - Start the ready thing (repo: alpha) (kind: ship) (since $today)
- [ ] m-held - Wait for the captain's call (repo: alpha) (kind: ship) (since $today) (hold: needs his call) (hold-kind: captain)
EOF
  cat > "$z/data/backlog.md" <<EOF
## Queued
- [ ] z-ready - Start the zephyrine thing (repo: alpha) (kind: ship) (since $today)
EOF
  # Deterministic device and machine probes, so nothing reads the host.
  printf '#!/bin/sh\nprintf "List of devices attached\\n\\n"\n' > "$fix/stubs/adb"
  # shellcheck disable=SC2016 # the single-quoted stub expands when it runs
  printf '#!/bin/sh\n[ "$1" = "-cf" ] && { echo 0; exit 0; }\nexit 1\n' > "$fix/stubs/pgrep"
  printf '#!/bin/sh\nprintf "MemoryCurrent=0\\nMemoryHigh=34359738368\\nMemoryMax=40802189312\\n"\n' > "$fix/stubs/systemctl"
  chmod +x "$fix/stubs/adb" "$fix/stubs/pgrep" "$fix/stubs/systemctl"
}

build() {  # <root> [env...]
  local fix=$1 out
  shift
  out=$(env PATH="$fix/stubs:$PATH" FM_HOME="$fix" HOME="$fix" FM_DEVICE_LOCK_DIR="$fix/locks" FM_DASHBOARD_PROC="$fix/proc" FM_MAC_HOST= "$@" "$DASH" build 2>&1) || fail "build failed: $out"
  [ "$out" = "$fix/state/dashboard/index.html" ] || fail "build did not print the page path: $out"
}

# The named home's backlog read fails; every other tasks-axi call is the real one.
stub_tasks_axi() {  # <stubs-dir> <fail-home> <real-tasks-axi>
  local dir=$1 fail_home=$2 real=$3
  # shellcheck disable=SC2016 # the single-quoted stub expands when it runs
  printf '#!/bin/sh\n[ "$FM_HOME" = "%s" ] && { echo "tasks-axi: backlog unreadable" >&2; exit 1; }\nexec "%s" "$@"\n' \
    "$fail_home" "$real" > "$dir/tasks-axi"
  chmod +x "$dir/tasks-axi"
}

main() {
  local fix d z real
  fix="$TMP/fleet" z="$TMP/fleet/mates/zephyrine" d="$TMP/fleet/state/dashboard"
  real=$(command -v tasks-axi)
  make_fixture "$fix"
  mkdir -p "$fix/proc/pressure" "$fix/locks"
  : > "$fix/proc/meminfo"
  : > "$fix/proc/locks"

  # One unread home: the readable home's counts stay, marked as a lower bound,
  # and the unread home is named with its reason.
  stub_tasks_axi "$fix/stubs" "$z" "$real"
  build "$fix"
  has "$d/index.html" \
    "Ready ≥1" "1 held · 0 waiting" "zephyrine: tasks-axi: backlog unreadable" \
    "Ready, a lane is free ≥1" "Queued 1 + 0 + 1 + 0 + 0 = ≥2"
  jq -e '
    .metrics.ready.status == "partial" and .metrics.ready.value == 1
    and (.metrics.ready.reason | contains("zephyrine"))
    and .metrics.queue.status == "partial" and .metrics.queue.value.ready == 1 and .metrics.queue.value.held == 1
    and .metrics.held_for_captain.status == "partial" and .metrics.lanes.status == "exact"
    and any(.queue_reasons[]; .reason == "Held for the captain" and .by_home.main == 1 and .by_home.zephyrine == null)' \
    "$d/data.json" >/dev/null || fail "data.json did not mark the partial backlog reading: $(jq -c '.metrics.ready, .metrics.queue, .queue_reasons' "$d/data.json")"
  # Tickets: the read home's items, the captain-held one On hold, and the unread home named instead of guessed.
  jq -e '.tickets_unread == ["zephyrine"] and ([.tickets[].task] | sort) == ["m-held", "m-ready"]
    and any(.tickets[]; .task == "m-held" and .state == "hold") and any(.tickets[]; .task == "m-ready" and .state == "todo" and .release == "later")' \
    "$d/board.json" >/dev/null || fail "board.json tickets did not follow the partial backlog: $(jq -c '.tickets, .tickets_unread' "$d/board.json")"

  # No home readable: back to the unknown dash, as before.
  printf '#!/bin/sh\necho "tasks-axi: backlog unreadable" >&2\nexit 1\n' > "$fix/stubs/tasks-axi"
  chmod +x "$fix/stubs/tasks-axi"
  build "$fix"
  has "$d/index.html" "Ready unknown:" "unknown: main: tasks-axi: backlog unreadable"
  jq -e '.metrics.ready.status == "unknown" and .metrics.ready.value == null and .metrics.queue.status == "unknown"' \
    "$d/data.json" >/dev/null || fail "an all-unread fleet was not unknown: $(jq -c '.metrics.ready, .metrics.queue' "$d/data.json")"
  pass "tickets list only the read homes and name the unread one; one unread home keeps the readable homes' Ready and queue counts, marked as a lower bound and named; no readable home falls back to unknown"
}

main
