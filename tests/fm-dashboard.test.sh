#!/usr/bin/env bash
# Behavior tests for bin/fm-dashboard.sh: build the pages from a small fixture
# fleet through the real script and the real tasks-axi, with stub herdr,
# quota-axi and device probes on PATH, then read each page's visible text
# the way a person would, and over `serve`.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DASH="$ROOT/bin/fm-dashboard.sh"
TMP_ROOT=$(fm_test_tmproot fm-dashboard)

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

# A page's visible text, one space between words.
page_text() {  # <page>
  python3 - "$1" <<'PY'
import html, re, sys
s = open(sys.argv[1]).read()
s = re.sub(r'<(style|title)>.*?</\1>', ' ', s, flags=re.S)
print(re.sub(r'\s+', ' ', html.unescape(re.sub(r'<[^>]+>', ' ', s))))
PY
}

has() {  # <page> <want>...: every phrase is in the page's visible text
  local page=$1 text want
  shift
  text=$(page_text "$page")
  for want in "$@"; do
    case "$text" in *"$want"*) ;; *) fail "$(basename "$page") lacks '$want': $text" ;; esac
  done
}

lacks() {  # <page> <phrase>...
  local page=$1 text bad
  shift
  text=$(page_text "$page")
  for bad in "$@"; do
    case "$text" in *"$bad"*) fail "$(basename "$page") shows '$bad': $text" ;; esac
  done
}

iso() {  # <hours ago> -> UTC ISO time
  python3 -c 'import sys; from datetime import datetime, timedelta, timezone as z
print((datetime.now(z.utc) - timedelta(hours=float(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"
}

lane() {  # <home> <task> <kind> <status line>...: a lane record whose last status line sets its state
  local home=$1 task=$2 kind=$3
  shift 3
  fm_write_meta "$home/state/$task.meta" "kind=$kind" "project=alpha" "harness=claude" "model=model-a" "herdr_pane_id=pane-$task"
  printf '%s\n' "$@" > "$home/state/$task.status"
}

summary() {  # <home> <state> <epoch> [json fields]: the summary a home publishes about itself
  printf '{"schema":"fm-secondmate-home-summary.v1","home":"%s","state":"%s","generated_epoch":%s%s}\n' "$1" "$2" "$3" "${4:+,$4}" > "$1/state/home-summary.json"
}

# A fleet of Main, one active lead (zephyrine) and one parked lead (beta).
# Lanes: Main has 2 building, 1 validating, 1 blocked, 1 on a decision, 1 finished,
# 1 waiting; zephyrine has 1 building; parked beta has 1 building that no total counts.
# Plan: Main 6 from config/lane-caps, every other home 3 from config/lane-target.
# Landed and closed today: one item each in Main and zephyrine; a day ago, 4 lanes were stuck.
make_home() {  # <name>
  local home="$TMP_ROOT/$1" now today held_day z b stubs
  now=$(date +%s) today=$(date +%F) held_day=$(date -d '7 days ago' +%F)
  z="$home/mates/zephyrine" b="$home/mates/beta" stubs="$home/stubs"
  mkdir -p "$home/data/metrics" "$home/state" "$home/config" "$z/data" "$z/state" "$b/data" "$b/state" "$stubs"
  printf -- '- zephyrine - made-up domain (home: %s; scope: made-up work; projects: alpha; added 2026-07-11)\n- beta - parked domain (home: %s; scope: parked; projects: alpha; added 2026-07-11)\n' \
    "$z" "$b" > "$home/data/secondmates.md"
  printf 'beta  # parked by the captain\n' > "$home/config/parked-homes"
  printf '3\n' > "$home/config/lane-target"
  printf 'main 6\n' > "$home/config/lane-caps"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] m-build - Build the main thing (repo: alpha) (kind: ship) (since $today)

## Queued
- [ ] m-ready - Start the ready thing (repo: alpha) (kind: ship) (since $today)
- [ ] m-held - Wait for the captain's call (repo: alpha) (kind: ship) (since $held_day) (hold: needs his call) (hold-kind: captain)
- [ ] m-after - After the ready thing blocked-by: m-ready (repo: alpha) (kind: ship) (since $today)

## Done
- [x] m-shipped - Ship the main thing (repo: alpha) (kind: ship) (merged $today)
- [x] m-old - Landed long ago (repo: alpha) (kind: ship) (merged 2026-07-10)
EOF
  # The archive repeats an item still in the backlog; it counts once.
  printf -- '- [x] m-shipped - Ship the main thing (repo: alpha) (kind: ship) (merged %s)\n' "$today" > "$home/data/done-archive.md"
  cat > "$z/data/backlog.md" <<EOF
## Queued
- [ ] z-ready - Start the zephyrine thing (repo: alpha) (kind: ship) (since $today)

## Done
- [x] z-shipped - Ship the zephyrine thing (repo: alpha) (kind: ship) (merged $today)
EOF
  cat > "$b/data/backlog.md" <<EOF
## In flight
- [ ] b-stale - A parked home's stale lane (repo: alpha) (kind: ship) (since 2026-10-01)
EOF
  lane "$home" m-build ship "working [at=$((now - 600))]: building"
  lane "$home" m-resume ship "blocked [at=$((now - 900))]: tests fail" "resolved [at=$((now - 300))]: back on it"
  lane "$home" m-ci ship "paused [at=$((now - 1200))]: waiting for CI checks https://github.com/acme/alpha/pull/9"
  lane "$home" m-stuck ship "blocked [at=$((now - 7200))]: cannot reach the build server"
  lane "$home" m-ask ship "needs-decision [at=$((now - 3600))] [key=scope]: which layout"
  lane "$home" m-done ship "done [at=$((now - 1800))]: PR https://github.com/acme/alpha/pull/8 checks green"
  lane "$home" m-wait scout "paused [at=$((now - 2400))]: waiting for the vendor's reply"
  lane "$z" z-build ship "working [at=$((now - 60))]: building"
  lane "$b" b-stale ship "working [at=$((now - 60))]: building"
  fm_write_meta "$home/state/zephyrine.meta" "kind=secondmate" "harness=claude" "model=lead-model" "herdr_pane_id=pane-lead"
  summary "$home" no_active_work "$now" '"endpoints":[{"id":"zephyrine","endpoint":{"exists":true,"agent_alive":"alive"}}]'
  summary "$z" active_child_work "$now"
  # Merges: zephyrine's on Main's channel for it, Main's own in its fleet ledger, which starts 2 days ago.
  printf 'done [key=merged-z-shipped] [at=%s]: merged z-shipped https://github.com/acme/alpha/pull/5\n' "$((now - 120))" > "$home/state/zephyrine.status"
  printf '{"ts":%s,"event":"ledger.started"}\n{"ts":%s,"event":"task.merged","task":"m-shipped","pr":"https://github.com/acme/alpha/pull/4"}\n' \
    "$((now - 172800))" "$((now - 60))" > "$home/state/fleet-ledger.jsonl"
  mkdir -p "$home/state/dashboard"
  printf '%s\t5\t4\t0\n' "$((now - 86400))" > "$home/state/dashboard/history.tsv"
  mkdir -p "$home/.cache/quota-axi"
  printf '{"schemaVersion":3,"generatedAt":"%s","credentials":{"token":"quota-secret-sentinel"},"providers":[{"provider":"codex","state":{"status":"fresh"},"windows":[{"id":"12h","percentUsed":79,"windowSeconds":43200,"resetsAt":"%s"}]},{"provider":"claude","state":{"status":"fresh"},"windows":[{"id":"7d","percentUsed":10,"windowSeconds":604800,"resetsAt":"%s"}]}]}\n' \
    "$(iso 0)" "$(iso -4)" "$(iso -72)" > "$home/quota.json"
  cp "$home/quota.json" "$home/.cache/quota-axi/quotas.json"
  printf '#!/bin/sh\necho called > "%s/quota.called"\nexit 1\n' "$home" > "$stubs/quota-axi"
  # Agents: a busy lead, a busy Main, one busy and one idle worker, one busy unknown agent, and a parked-home worker.
  cat > "$home/herdr.json" <<EOF
{"result":{"agents":[
 {"agent":"claude","agent_status":"working","cwd":"$z","pane_id":"pane-lead","name":"lead"},
 {"agent":"claude","agent_status":"working","cwd":"$home","pane_id":"pane-main","name":"main"},
 {"agent":"claude","agent_status":"working","cwd":"/wt/1","pane_id":"pane-m-build","name":"w1"},
 {"agent":"claude","agent_status":"idle","cwd":"/wt/2","pane_id":"pane-m-ask","name":"w2"},
 {"agent":"codex","agent_status":"working","cwd":"/elsewhere/odd-job","pane_id":"pane-x","name":"odd-job"},
 {"agent":"claude","agent_status":"working","cwd":"/wt/3","pane_id":"pane-b-stale","name":"w3"}]}}
EOF
  cat > "$stubs/herdr" <<EOF
#!/bin/sh
[ -e "$home/herdr.fail" ] && { echo 'herdr: server not running' >&2; exit 1; }
cat "$home/herdr.json"
EOF
  printf '#!/bin/sh\nprintf "List of devices attached\\n\\n"\n' > "$stubs/adb"
  # shellcheck disable=SC2016 # the single-quoted stub expands when it runs
  printf '#!/bin/sh\n[ "$1" = "-cf" ] && { echo 0; exit 0; }\nexit 1\n' > "$stubs/pgrep"
  printf '#!/bin/sh\nprintf "MemoryCurrent=0\\nMemoryHigh=34359738368\\nMemoryMax=40802189312\\n"\n' > "$stubs/systemctl"
  mkdir -p "$home/proc/pressure"
  printf 'MemTotal: 67108864 kB\nMemAvailable: 33554432 kB\n' > "$home/proc/meminfo"
  printf 'some avg10=0.00\n' > "$home/proc/pressure/memory"
  : > "$home/proc/locks"
  mkdir -p "$home/locks"
  chmod +x "$stubs/herdr" "$stubs/adb" "$stubs/pgrep" "$stubs/systemctl" "$stubs/quota-axi"
  printf '%s\n' "$home"
}

build() {  # <home> [env...]: build with the fixture's stubs first on PATH
  local home=$1 out
  shift
  out=$(env PATH="$home/stubs:$PATH" FM_HOME="$home" HOME="$home" FM_DEVICE_LOCK_DIR="$home/locks" FM_DASHBOARD_PROC="$home/proc" FM_MAC_HOST= "$@" "$DASH" build 2>&1) || fail "build failed: $out"
  [ "$out" = "$home/state/dashboard/index.html" ] || fail "build did not print the page path: $out"
}

test_overview_answers_the_four_questions_with_sums_that_add_up() {
  local home d now
  home=$(make_home overview)
  d="$home/state/dashboard"
  printf '%s\t100\t99\t98\n%s\t5\t4\t0\n' "$(( $(date +%s) - 88100 ))" "$(( $(date +%s) - 86400 ))" > "$d/history.tsv"
  build "$home"
  jq -e '([.. | strings] | index("quota-secret-sentinel") == null) and (.quota_accounts[0].windows[0] | .status == "projected_exhaustion" and .pace > 66 and .pace < 67)'  "$d/data.json" >/dev/null || fail "even-pace runway was not derived from cache windows"
  for p in index backlog backlog.home measure; do
    [ -s "$d/$p.html" ] || fail "no $p page"
    ! grep -Eq '<script|https?://[^"]*\.(css|js)"' "$d/$p.html" || fail "$p is not self-contained"
  done
  # Chips name each spot with a number and an age; tiles compare with yesterday and the sample a day ago.
  has "$d/index.html" "Nothing needs you. ✕ 2 stuck 2 h ▲ 1 to land 30 min ▲ 1 held for triage 7 d ▲ 1 idle with ready work today" \
    "Landed today at least 2" "Closed 7 d 2 +2" "Lanes open 8 of 9 +3 3 building · 1 free" "Stuck 2 -2 1 blocked · oldest 2 h" \
    "Quota runs out 2 h" "Codex before its reset" "Codex out" "Claude resets" "Ready 2 +2"
  # Each lane is in one state and each queued item has one reason, summing to their totals.
  has "$d/index.html" "Blocked 1 2 h" "On a decision 1 1 h" "Finished, not landed 1 30 min" "Validating or CI 1 20 min" \
    "Waiting on other 1 40 min" "Building 3 10 min" "Queued 1 + 1 + 1 + 0 + 1 = 4" \
    "Ship the main thing Main" "Ship the zephyrine thing zephyrine" "Main 7 of 6 1 at least 1 1 zephyrine 1 of 3 1 at least 1 1" \
    "beta is parked by the captain and left out of every total."
  # The busy parts sum to the busy total, and the denominator is every running Herdr agent
  # outside parked homes (6 listed, 1 in parked beta), not the lane plan of 9.
  running=$(jq '[.result.agents[] | select(.pane_id != "pane-b-stale")] | length' "$home/herdr.json")
  [ "$running" = 5 ] || fail "fixture should list 5 running agents outside parked homes, has $running"
  has "$d/backlog.html" "Busy now 1 + 1 + 1 + 1 = 4" "the groups list all $running running agents"
  lacks "$d/index.html" "A parked home's stale lane" "w3"
  # Main's ask list is the only thing in the hero; held items are a slow spot, never "Waiting on you".
  now=$(date +%s)
  printf 'first\t%s\tApprove the release\thttps://example.invalid/release\nsecond\t%s\tChoose a date\t\n' \
    "$((now - 7200))" "$((now - 3600))" > "$home/data/captain-asks.tsv"
  build "$home"
  has "$d/index.html" "2 things need you. Approve the release 2 h Choose a date 1 h"
  grep -q 'href="https://example.invalid/release"' "$d/index.html" || fail "ask URL not linked"
  # A blank row, or one without an id or text, is not an ask; a real ask with a bad time still counts.
  printf '\nbad row\n\t%s\tNo id\t\nfourth\t%s\t\t\nfifth\tsoon\tFix the time\t\n' "$now" "$now" >> "$home/data/captain-asks.tsv"
  build "$home"
  has "$d/index.html" "3 things need you." "Approve the release" "Choose a date" "Ask record needs correction"
  lacks "$d/index.html" "No id" "4 things need you." "5 things need you."
  has "$d/measure.html" "data/captain-asks.tsv row 4 skipped: no id or text" "row 5 skipped: no id or text" \
    "row 6 skipped: no id or text" "data/captain-asks.tsv malformed row 7"
  pass "the overview answers each question, and lanes, agents and groups sum to their totals"
}

test_backlog_and_method_pages_show_their_numbers() {
  local home d
  home=$(make_home pages)
  d="$home/state/dashboard"
  build "$home"
  has "$d/backlog.html" "Queued 4 = Ready 2 + Held 1 + Waiting on another item 1" \
    "1 item held; oldest" "Wait for the captain's call" "needs his call" \
    "Open lanes 2 + 1 + 4 + 1 = 8" "Busy now 1 + 1 + 1 + 1 = 4" "4 busy: 1 lead + 1 Main + 1 worker + 1 other." \
    "Lane settings plan 9 lanes; 8 are open." "Fleet 8 9 2" "Main 6" \
    "Oldest validation or CI wait: 20 min (m-ci, Main)"
  has "$d/backlog.home.html" "Queued" "Main 3" "zephyrine 1" "Open lanes 7 + 1 = 8"
  has "$d/backlog.html" "Plan per home from the lane settings (Main 6); every other home 3."
  has "$d/measure.html" "every 60 s" "Parked homes are left out (beta)." "beta is parked but has 1 item marked in flight" \
    "Landed Counts pull requests the fleet recorded as merged, each once" "Every source was read."
  pass "Backlog and Method pages show their numbers with windows and sums"
}

test_each_failed_source_shows_unknown_and_why() {
  local home d
  home=$(make_home failing)
  d="$home/state/dashboard"
  build "$home"
  touch "$home/herdr.fail"
  # A home whose backlog cannot be read makes the queue unknown, and names the home.
  printf '#!/bin/sh\necho "tasks-axi: backlog unreadable" >&2\nexit 1\n' > "$home/stubs/tasks-axi"
  chmod +x "$home/stubs/tasks-axi"
  build "$home"
  has "$d/measure.html" "herdr agent list herdr: server not running"
  has "$d/backlog.html" "Queued work unknown." "main: tasks-axi: backlog unreadable" "At least 0 items held; the backlog of Main, zephyrine is unknown." "Agents unknown."
  has "$d/measure.html" "backlog main: tasks-axi: backlog unreadable"
  lacks "$d/backlog.html" "Queued 0" "No item is held" "0 busy"
  jq --arg at "$(iso 1)" '.generatedAt=$at | .providers[].state.stale=true' "$home/.cache/quota-axi/quotas.json" > "$home/q.json" && mv "$home/q.json" "$home/.cache/quota-axi/quotas.json"
  build "$home"
  has "$d/index.html" "Codex out" "as of"
  lacks "$d/index.html" "Quota runs out unknown"
  [ ! -e "$home/quota.called" ] || fail "page build collected quota"
  jq -e '.since == null and .last == null' "$d/filed.json" >/dev/null || fail "failed backlog read advanced filing coverage"
  rm "$home/.cache/quota-axi/quotas.json" "$home/mates/zephyrine/state/home-summary.json"
  build "$home"
  has "$d/index.html" "Quota runs out unknown" "▲ 1 lead to check" "zephyrine State unknown"
  has "$d/measure.html" "home summary zephyrine: No such file or directory"
  lacks "$d/index.html" "Codex"
  pass "each failed source shows unknown and why, and never guesses zero"
}

test_devices_and_machine_come_from_read_only_probes() {
  local home d proc locks bin key at nopath
  home=$(make_home probes)
  d="$home/state/dashboard"
  proc="$home/proc" locks="$home/locks" bin="$home/stubs"
  mkdir -p "$proc/pressure" "$proc/900" "$proc/800" "$locks" "$home/projects/wt"
  fm_write_meta "$home/state/m-build.meta" "kind=ship" "worktree=$home/projects/wt" "herdr_pane_id=pane-m-build"
  printf 'MemTotal:       67108864 kB\nMemAvailable:   10485760 kB\nSwapTotal:      33554432 kB\nSwapFree:       29360128 kB\n' > "$proc/meminfo"
  printf 'some avg10=3.50 avg60=8.00 avg300=12.00 total=1\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' > "$proc/pressure/memory"
  # The watcher's recorded samples: only the last hour counts toward the peak.
  printf '%s\t1\t1\t88.00\tALERT\n%s\t1\t1\t41.20\tALERT\n%s\t1\t1\t6.00\tOK\n' \
    "$(( $(date +%s) - 7200 ))" "$(( $(date +%s) - 600 ))" "$(date +%s)" > "$home/state/host-memory.tsv"
  printf '%s\tnope-mem\tpressure at or above 20%%\n' "$(( $(date +%s) - 120 ))" > "$home/state/admission-refused"
  printf 'Name:\tqemu-system-x86\nVmRSS:\t 4194304 kB\n' > "$proc/900/status"
  printf '900 (qemu-system-x86) S 800 900 1\n' > "$proc/900/stat"
  printf '800 (flock) S 1 800 1\n' > "$proc/800/stat"
  : > "$locks/fm-phone-PHONE1.lock"
  : > "$locks/fm-phone-muxr-emu.lock"
  # The kernel lists a held flock by device and inode; only the emulator lock is held.
  key=$(python3 -c 'import os,sys; s=os.stat(sys.argv[1]); print(f"{os.major(s.st_dev):02x}:{os.minor(s.st_dev):02x}:{s.st_ino}")' "$locks/fm-phone-muxr-emu.lock")
  printf '1: FLOCK  ADVISORY  WRITE 800 %s 0 EOF\n' "$key" > "$proc/locks"
  at=$(iso 0.17)
  printf '%s PHONE1 acquired pid=700 waited=0s cwd=/tmp/fm-m-build\n%s PHONE1 released pid=700 rc=0\n%s muxr-emu acquired pid=800 waited=0s cwd=%s\n' \
    "$at" "$at" "$at" "$home/projects/wt/app" > "$locks/fm-device-lock.log"
  cat > "$bin/adb" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$home/adb.calls"
[ -e "$home/adb.fail" ] && { echo 'error: daemon not running' >&2; exit 1; }
printf 'List of devices attached\nPHONE1 device usb:1-1 product:p model:Pixel_9 device:d transport_id:1\nemulator-5554 device product:sdk model:sdk transport_id:2\n\n'
EOF
  cat > "$bin/pgrep" <<'EOF'
#!/bin/sh
case "$*" in
  "-a ^qemu-system") echo '900 /opt/emulator/qemu-system-x86_64 -netdelay none -avd test-avd -port 5554' ;;
  "-cf appname=gradle[w]") echo 2 ;;
  *) exit 1 ;;
esac
EOF
  cat > "$bin/systemctl" <<EOF
#!/bin/sh
[ -e "$home/systemctl.fail" ] && { echo 'Failed to connect to bus' >&2; exit 1; }
printf 'MemoryCurrent=8589934592\nMemoryHigh=34359738368\nMemoryMax=40802189312\n'
EOF
  chmod +x "$bin/adb" "$bin/pgrep" "$bin/systemctl"
  build "$home" FM_DASHBOARD_PROC="$proc" FM_DEVICE_LOCK_DIR="$locks"
  has "$d/index.html" "In use 1" "Free 1" "Devices 1 + 1 = 2" \
    "Phone Pixel 9 Free · last used by Main 10 min ago · PHONE1 · USB" \
    "Emulator test-avd In use by Main · 10 min · emulator-5554 · 4.0 GB in use" \
    "Free memory 10.0 GB of 64 GB" "Memory pressure 4% share of the last 10 s" "Heavy jobs 8.0 GB of 32 GB" "hard limit 38 GB" \
    "Gradle builds 2 of 2" "Emulators 1 of 2" "✕ 10 GB free, heavy jobs wait" "▲ 2/2 Gradle builds at cap" \
    "Pressure peak, last hour 41%" "Swap used 4.0 GB" "new agents wait (Main)" "nope-mem"
  lacks "$d/index.html" "Pressure peak, last hour 88%"
  [ "$(sort -u "$home/adb.calls")" = "devices -l" ] || fail "adb was asked more than the device list: $(cat "$home/adb.calls")"
  jq -e '.metrics.devices.value == 2 and .metrics.connected_devices.value == 2 and .metrics.device_groups.value.action == {"In use":1,"Free":1} and .metrics.device_groups.value.home == {"Main":1,"No holder":1}' "$d/data.json" >/dev/null || fail "device groups differ from the page"
  printf 'List of devices attached\nPHONE1 device model:Pixel_9\nOFFLINE offline model:Pixel_8\n' > "$home/adb-output"
  printf '#!/bin/sh\ncat "%s/adb-output"\n' "$home" > "$bin/adb"
  # shellcheck disable=SC2016 # the single-quoted stub expands when it runs
  printf '#!/bin/sh\n[ "$1" = "-cf" ] && { echo 0; exit 0; }\nexit 1\n' > "$bin/pgrep"
  build "$home" FM_DASHBOARD_PROC="$proc"
  has "$d/index.html" "Problem 1" "In use 1" "Free 1" "Devices 1 + 1 + 1 = 3" "Lock muxr-emu"
  jq -e '.metrics.devices.value == 3 and .metrics.connected_devices.value == 1 and .metrics.device_groups.value.action == {"Problem":1,"In use":1,"Free":1} and (.devices | length) == 3' "$d/data.json" >/dev/null || fail "offline devices or unmatched locks disappeared from JSON"
  printf '#!/bin/sh\n[ -e "%s/adb.fail" ] && { echo "error: daemon not running" >&2; exit 1; }\ncat "%s/adb-output"\n' "$home" "$home" > "$bin/adb"
  # Memory pressure is one number, the gate's 10 s share, in the chip and the card alike.
  printf 'MemTotal:       67108864 kB\nMemAvailable:   20971520 kB\n' > "$proc/meminfo"
  printf 'some avg10=45.00 avg60=8.00 avg300=12.00 total=1\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' > "$proc/pressure/memory"
  build "$home" FM_DASHBOARD_PROC="$proc" FM_DEVICE_LOCK_DIR="$locks"
  has "$d/index.html" "✕ 45% memory pressure, heavy jobs wait" "Memory pressure 45%"
  lacks "$d/index.html" "12%"
  rm "$proc/locks"
  build "$home" FM_DASHBOARD_PROC="$proc"
  has "$d/index.html" "Unknown 2"
  lacks "$d/index.html" "Free 1"
  jq -e '.metrics.device_groups.status == "unknown" and .metrics.device_groups.value == null and all(.devices[]; .holder == null)' "$d/data.json" >/dev/null || fail "unknown ownership exported as free capacity"
  # Each failed probe says unknown and why; nothing is guessed as zero.
  touch "$home/adb.fail" "$home/systemctl.fail"
  rm "$proc/meminfo"
  build "$home" FM_DASHBOARD_PROC="$proc" FM_DEVICE_LOCK_DIR="$locks"
  has "$d/index.html" "unknown - adb: error: daemon not running" \
    "Free memory unknown: $proc/meminfo: No such file or directory" "Heavy jobs unknown: Failed to connect to bus" \
    "unknown - device locks: $proc/locks: No such file or directory"
  lacks "$d/index.html" "0 devices connected" "Free memory 0"
  # A server whose PATH lacks adb still finds it in the Android SDK, and says not found only when neither has it.
  rm "$home/adb.fail"
  mkdir -p "$home/sdk/platform-tools"
  mv "$bin/adb" "$home/sdk/platform-tools/adb"
  # PATH keeps every tool but adb: a directory holding adb is replaced by links to its other files.
  mkdir -p "$home/noadb"
  nopath=$bin$(printf '%s' "$PATH" | tr ':' '\n' | while IFS= read -r p; do
    if [ -x "$p/adb" ]; then find "$p" -maxdepth 1 ! -name adb ! -type d -exec ln -s {} "$home/noadb/" \; 2>/dev/null; printf ':%s' "$home/noadb"
    else printf ':%s' "$p"; fi; done)
  build "$home" PATH="$nopath" ANDROID_HOME="$home/sdk" FM_DASHBOARD_PROC="$proc" FM_DEVICE_LOCK_DIR="$locks"
  has "$d/index.html" "Phone Pixel 9"
  build "$home" PATH="$nopath" HOME="$home" ANDROID_HOME= ANDROID_SDK_ROOT= FM_DASHBOARD_PROC="$proc" FM_DEVICE_LOCK_DIR="$locks"
  has "$d/index.html" "unknown - adb: adb not found"
  pass "devices and machine come from read-only probes, name each holder's home, and say unknown with the reason"
}

SERVE_PID=
trap '[ -z "$SERVE_PID" ] || kill "$SERVE_PID" 2>/dev/null; fm_test_cleanup' EXIT

test_serve_answers_each_page_and_remembers_the_grouping() {
  local home url got
  home=$(make_home served)
  PATH="$home/stubs:$PATH" FM_HOME="$home" HOME="$home" FM_DEVICE_LOCK_DIR="$home/locks" "$DASH" serve --port 0 > "$home/serve.out" 2> "$home/serve.err" &
  SERVE_PID=$!
  for _ in $(seq 1 100); do
    url=$(sed -n 's/^serving //p' "$home/serve.out")
    [ -n "$url" ] && break
    kill -0 "$SERVE_PID" 2>/dev/null || fail "serve exited: $(cat "$home/serve.err")"
    sleep 0.1
  done
  [ -n "$url" ] || fail "serve never reported its address: $(cat "$home/serve.err")"
  case "$url" in http://127.0.0.1:*/) ;; *) fail "serve did not default to loopback: $url" ;; esac
  got=$(python3 - "$url" "$ROOT/bin/fm-dashboard/index.html" <<'PY'
import json, re, sys, urllib.request, urllib.error
def get(u, cookie=None):
    rq = urllib.request.Request(u, headers={'Cookie': cookie} if cookie else {})
    try:
        with urllib.request.urlopen(rq, timeout=120) as r: return r.status, r.read().decode(), r.headers.get('Set-Cookie') or ''
    except urllib.error.HTTPError as e: return e.code, '', ''
base, shell_path = sys.argv[1:3]
APP_SHELL = open(shell_path, 'rb').read()
with urllib.request.urlopen(base + 'data.json', timeout=120) as r:
    assert r.headers.get_content_type() == 'application/json'
    data = json.load(r)
assert data['build_duration_seconds'] >= 0 and data['build_time']
m = data['metrics']
assert m['lanes']['value'] == 8 and m['lanes']['status'] == 'exact'
assert m['free_lanes']['value'] == 1 and m['ready']['value'] == 2
assert m['landed']['value'] == 2 and m['landed']['status'] == 'lower_bound'
assert m['closed']['value'] == 2 and m['filed']['status'] == 'lower_bound'
assert len(data['lanes']) == 8 and len(data['homes']) == 2
assert data['held_items'][0]['reason'] == 'needs his call'
for metric in m.values():
    assert metric['status'] in ('exact', 'lower_bound', 'unknown')
    assert all(k in metric for k in ('value', 'reason', 'source', 'window', 'cutoff', 'read_at'))
    if metric['status'] == 'unknown': assert metric['value'] is None and metric['reason']
with urllib.request.urlopen(urllib.request.Request(base + 'data.json', method='HEAD')) as r:
    assert r.headers.get_content_type() == 'application/json' and r.read() == b''
    assert int(r.headers['Content-Length']) > 0
for path, want in (('backlog', 'Held for the captain'), ('measure', 'How each number is measured.')):
    code, body, _ = get(base + path)
    print(path, code, want in body)
code, body, cookie = get(base + 'backlog?group=home')
print('group', code, 'fm_group=home' in cookie, '7 + 1 = <b>8</b>' in body)
code, body, _ = get(base + 'backlog', 'fm_group=home')
print('cookie', code, '7 + 1 = <b>8</b>' in body)
code, body, _ = get(base + 'measure')
print('timestamps', '<!--' not in body, re.search(r'as of \d\d:\d\d', body) is not None)
for path in ('flow', 'state/', 'index.home.html', '../data/backlog.md', 'data/backlog.md'):
    print(path, get(base + path)[0])
def raw(u, **h):
    try:
        with urllib.request.urlopen(urllib.request.Request(u, headers=h), timeout=120) as r: return r.status, r.headers, r.read()
    except urllib.error.HTTPError as e: return e.code, e.headers, b''
# The app and its files: its own origin only, each file answered 304 while unchanged; the pages keep their own policy.
s, h, b = raw(base)
print('app', s, h.get_content_type(), "default-src 'self'" in h['Content-Security-Policy'], b == APP_SHELL)
for path in ('app.js', 'vendor/preact-htm-3.1.1.js', 'board.json'):
    s, h, b = raw(base + path)
    print(path, s, h.get_content_type(), h['Cache-Control'], raw(base + path, **{'If-None-Match': h['ETag']})[0])
s, h, b = raw(base + 'overview')
print('overview-app', s, "default-src 'self'" in h['Content-Security-Policy'], b == APP_SHELL)
print('board', json.loads(raw(base + 'board.json')[2])['schema'], "default-src 'none'" in raw(base + 'backlog')[1]['Content-Security-Policy'])
import gzip
s, h, b = raw(base + 'board.json', **{'Accept-Encoding': 'gzip'})
print('gzip', h['Content-Encoding'], json.loads(gzip.decompress(b))['schema'], raw(base + 'board.json', **{'Accept-Encoding': 'gzip', 'If-None-Match': h['ETag']})[0])
for path in ('vendor/../app.js', '../fm-dashboard/app.js', '.hidden.js', 'a/b/app.js', 'app.py', 'missing.js'):
    print(path, raw(base + path)[0])
# The Ship tab's module, its pinned three.js and its stylesheet come from the same origin the same way.
for path in ('ship/index.js', 'ship/scene.js', 'vendor/three-0.186.1.min.js', 'ship/ship.css'):
    s, h, b = raw(base + path)
    print(path, s, h.get_content_type(), raw(base + path, **{'If-None-Match': h['ETag']})[0])
PY
)
  [ "$got" = "$(printf '%s\n' 'backlog 200 True' 'measure 200 True' \
    'group 200 True True' 'cookie 200 True' 'timestamps True True' 'flow 404' 'state/ 404' 'index.home.html 404' '../data/backlog.md 404' 'data/backlog.md 404' \
    'app 200 text/html True True' 'app.js 200 text/javascript no-cache 304' 'vendor/preact-htm-3.1.1.js 200 text/javascript no-cache 304' \
    'board.json 200 application/json no-cache 304' 'overview-app 200 True True' 'board fm-dashboard-board.v1 True' 'gzip gzip fm-dashboard-board.v1 304' 'vendor/../app.js 404' '../fm-dashboard/app.js 404' \
    '.hidden.js 404' 'a/b/app.js 404' 'app.py 404' 'missing.js 404' 'ship/index.js 200 text/javascript 304' 'ship/scene.js 200 text/javascript 304' \
    'vendor/three-0.186.1.min.js 200 text/javascript 304' 'ship/ship.css 200 text/css 304')" ] \
    || fail "serve answers were not the app, the three pages, the remembered grouping, then 404s: $got"
  # An old page is answered at once, as it is, while a rebuild runs behind it.
  printf '<p>old page<!--age--></p>\n' > "$home/state/dashboard/backlog.html"
  touch -d '-5 minutes' "$home/state/dashboard/index.html"
  got=$(python3 -c 'import sys, urllib.request; print(urllib.request.urlopen(sys.argv[1], timeout=5).read().decode())' "${url}backlog")
  case "$got" in *'<span class="age bad">updated 5'*'min ago'*) ;; *) fail "an old page was not answered at once, marked old: $got" ;; esac
  for _ in $(seq 1 1200); do grep -q 'old page' "$home/state/dashboard/backlog.html" || break; sleep 0.1; done
  grep -q 'Held for the captain' "$home/state/dashboard/backlog.html" || fail "the background rebuild did not replace the old page"
  python3 - "$url" "$home" <<'PY' || fail "failed rebuild reported a healthy JSON refresh"
import os, time, sys, urllib.request, urllib.error
base, home = sys.argv[1:]
with urllib.request.urlopen(base + 'board.json') as r: tag = r.headers['ETag']
os.unlink(home + '/state/dashboard/backlog.html')
os.mkdir(home + '/state/dashboard/backlog.html')
os.utime(home + '/state/dashboard/index.html', (time.time() - 300,) * 2)
deadline = time.monotonic() + 15
while 'last refresh failed' not in urllib.request.urlopen(base + 'measure').read().decode():
    assert time.monotonic() < deadline, 'rebuild never failed'
    time.sleep(.1)
for path in ('board.json', 'data.json'):
    for headers in ({}, {'If-None-Match': tag}):
        try: urllib.request.urlopen(urllib.request.Request(base + path, headers=headers))
        except urllib.error.HTTPError as e: assert e.code == 503 and e.headers['Cache-Control'] == 'no-store'
        else: raise AssertionError('failed refresh answered successfully')
PY
  kill "$SERVE_PID" 2>/dev/null; SERVE_PID=
  pass "serve answers the app, its files and the Ship tab's files by version, the three pages at once retaining source timestamps, remembers ?group in a cookie, rebuilds an old page itself, and 404s every other path"
}

test_board_json_feeds_the_app() {
  local home d now today
  home=$(make_home board)
  d="$home/state/dashboard"
  now=$(date +%s) today=$(date +%F)
  # A lane in review on Opus; m-fix ran 3 h on GPT and merged a minute ago, its archived title ending in its PR.
  fm_write_meta "$home/state/m-opus.meta" "kind=ship" "project=alpha" "harness=claude" "model=claude-opus-5-5" "herdr_pane_id=pane-m-opus"
  printf '%s\n' "working [at=$((now - 3000))]: building" "working [at=$((now - 900))] [key=nm-run-review]: no-mistakes review" "working [at=$((now - 600))] [key=nm-run-ci]: CI checks" "needs-decision [at=$((now - 300))] [key=nm-newrun-review]: waiting for vendor credentials" > "$home/state/m-opus.status"
  lane "$home" m-ci ship "blocked [at=$((now - 1200))]: CI failed: approve config/release.json https://github.com/acme/alpha/pull/9"
  lane "$home" m-paused ship "paused [at=$((now - 200))] [key=nm-run-test]: waiting for vendor credentials"
  lane "$home" m-gitlab ship "working [at=$((now - 900))] [key=nm-run-ci]: checks running" "done [at=$((now - 300))]: PR https://gitlab.example/team/nested/app/-/merge_requests/27 checks green"
  fm_write_meta "$home/state/m-canonical.meta" "kind=ship" "project=alpha" "pr=https://review.example/c/team/app/+/28"
  printf 'working [at=%s] [key=nm-run-ci]: checks running\n' "$now" > "$home/state/m-canonical.status"
  lane "$home" m-gerrit ship "done [at=$((now - 200))]: PR https://review.example/c/team/nested/app/+/27 published for review"
  printf '{"v":1,"ts":%s,"event":"task.dispatched","task":"m-opus","harness":"claude"}\n{"v":1,"ts":%s,"event":"task.dispatched","task":"m-fix","model":"gpt-5.5","harness":"codex"}\n{"v":1,"ts":%s,"event":"task.merged","task":"m-fix","pr":"https://github.com/acme/alpha/pull/12"}\n' \
    "$((now - 3600))" "$((now - 10800))" "$((now - 600))" >> "$home/state/fleet-ledger.jsonl"
  printf -- '- [x] m-fix - Fix the login PR https://github.com/acme/alpha/pull/12 (repo: alpha) (kind: ship) (merged %s)\n' "$today" >> "$home/data/done-archive.md"
  printf 'first\t%s\tApprove the release\thttps://example.invalid/release\n' "$((now - 7200))" > "$home/data/captain-asks.tsv"
  fm_write_meta "$home/state/m-fix.meta" "kind=ship" "project=alpha" "pr=https://github.com/acme/alpha/pull/12"
  printf 'working [at=%s] [key=nm-run-ci]: checks running\n' "$now" > "$home/state/m-fix.status"
  build "$home"
  jq -e --argjson now "$now" '
    def c($id): .cards[] | select(.id == $id);
    .schema == "fm-dashboard-board.v1" and ([.stages[].id] == ["queued","building","review","test","ci","merge","landed"])
    and (c("main/m-opus") | .stage == "review" and .model == "opus" and .model_name == "Opus" and .started == $now - 3600 and .since == $now - 300
      and .reached.review == $now - 900 and .reached.ci == $now - 600 and .wait == "decision"
      and ([.history[] | [.v, .stage]] == [["working","building"],["working","review"],["working","ci"],["needs-decision","review"]]))
    and (c("main/m-stuck") | .wait == "blocked" and .why == "cannot reach the build server")
    and (c("main/m-ask") | .wait == "decision" and .why == "which layout")
    and (c("main/m-done") | .stage == "merge" and .why == "PR 8 checks green" and .pr == "https://github.com/acme/alpha/pull/8" and .history[0].v == "done" and .history[0].stage == "merge")
    and (c("main/m-ci") | .stage == "ci" and .wait == "blocked" and .wait_since == $now - 1200)
    and (c("main/m-paused") | .stage == "test" and .wait == "waiting")
    and (c("main/m-gitlab") | .stage == "merge" and .since == $now - 300 and .pr == "https://gitlab.example/team/nested/app/-/merge_requests/27")
    and (c("main/m-canonical") | .pr == "https://review.example/c/team/app/+/28")
    and (c("main/m-gerrit") | .pr == "https://review.example/c/team/nested/app/+/27" and .stage == "review")
    and (c("main/m-fix@https://github.com/acme/alpha/pull/12") | .stage == "landed" and .title == "Fix the login" and .pr == "https://github.com/acme/alpha/pull/12" and .started == $now - 10800 and .model == "gpt")
    and ([.cards[] | select(.stage == "queued") | .id] == ["main/m-ready","zephyrine/z-ready"])
    and .parked == ["beta"] and ([.cards[] | select(.home == "beta")] == [])
    and all(.cards[]; .id != "main/m-fix") and .cycle_p50 == null
    and ([.asks[] | [.id, .text, .url]] == [["first","Approve the release","https://example.invalid/release"]])
    and .landed[-1] == 3' "$d/board.json" >/dev/null ||
    fail "board.json does not carry each lane's stage, wait, model, reason and the day's landings: $(jq -c '{cards: [.cards[] | {id, stage, wait, why, model, title}], asks, landed, cycle_p50}' "$d/board.json")"
  jq -e '.flow.schema == "fm-flow.v1" and .flow_error == null
    and .flow.time_to_merge.median_seconds == 10200 and .flow.time_to_merge.p85_seconds == 10200
    and .flow.time_to_merge.known == 1 and .flow.time_to_merge.unknown == 1
    and (.flow.executed_7d | length) == 2
    and any(.flow.lanes[]; .task == "m-fix" and .display_title == "Fix the login"
      and (.times | has("first_commit") | not)
      and .pr == "https://github.com/acme/alpha/pull/12")
    and any(.flow.queue[]; .task == "m-after" and .display_why == "Waiting for: Start the ready thing")
    and any(.flow.bottlenecks[]; .cause == "credential_external" and .additive == false)
    and .flow.capacity.observed_at >= .flow.at
    and .flow.capacity.mac.reachable == null' "$d/board.json" >/dev/null || fail "Insights observation checks: $(jq -c '{present:(.flow!=null),reader_ok:(.flow_error==null),median:.flow.time_to_merge.median_seconds,p85:.flow.time_to_merge.p85_seconds,known:.flow.time_to_merge.known,unknown:.flow.time_to_merge.unknown,merged:(.flow.executed_7d|length),title_ok:any(.flow.lanes[];.task=="m-fix" and .display_title=="Fix the login"),link_ok:any(.flow.lanes[];.task=="m-fix" and .pr=="https://github.com/acme/alpha/pull/12"),dependency_ok:any(.flow.queue[];.task=="m-after" and .display_why=="Waiting for: Start the ready thing"),cause_ok:any(.flow.bottlenecks[];.cause=="credential_external" and .additive==false),capacity_ok:(.flow.capacity.observed_at>=.flow.at),mac_unknown:(.flow.capacity.mac.reachable==null)}' "$d/board.json")"
  jq -e '.models.schema == "fm-model-stats.v1" and .models_error == null
    and .models.windows == [7, 30] and (.models.models | type) == "array"' \
    "$d/board.json" >/dev/null || fail "Insights is missing the Models statistics: $(jq -c '{present:(.models!=null),error:.models_error}' "$d/board.json")"
  jq -e '.skills.schema == "fm-skill-stats.v1" and .skills_error == null
    and .skills.windows == [7, 30] and (.skills.skills | type) == "array" and (.skills.by_home | type) == "object"' \
    "$d/board.json" >/dev/null || fail "Insights is missing the Skills statistics: $(jq -c '{present:(.skills!=null),error:.skills_error}' "$d/board.json")"

  printf '{"ts":%s,"event":"task.merged","task":"m-gitlab","pr":"https://gitlab.example/team/nested/app/-/merge_requests/27"}\n{"ts":%s,"event":"task.merged","task":"m-gerrit","pr":"https://review.example/c/team/nested/app/+/27"}\n' "$((now - 60))" "$((now - 60))" >> "$home/state/fleet-ledger.jsonl"
  printf 'done [key=merged-z-lab] [at=%s]: merged z-lab https://gitlab.example/team/app/-/merge_requests/50\ndone [key=merged-z-review] [at=%s]: merged z-review https://review.example/c/team/app/+/51\n' "$((now - 60))" "$((now - 60))" >> "$home/state/zephyrine.status"
  printf -- '- zephyrine - remote (host: distant; root: /srv; home: %s; scope: work; projects: alpha; added 2026-07-11)\n' "$home/mates/zephyrine" > "$home/data/secondmates.md"
  printf '{"ts":%s,"event":"task.dispatched","task":"z-shipped","model":"gpt-5.5"}\n' "$((now - 5000))" >> "$home/mates/zephyrine/state/fleet-ledger.jsonl"
  for i in 1 2 3 4; do
    printf '{"ts":%s,"event":"task.dispatched","task":"m-cycle%s","model":"gpt-5.5"}\n{"ts":%s,"event":"task.merged","task":"m-cycle%s","pr":"https://github.com/acme/alpha/pull/%s"}\n' "$((now - 60 - i * 1000))" "$i" "$((now - 60))" "$i" "$((20 + i))" >> "$home/state/fleet-ledger.jsonl"
  done
  printf '{"ts":%s,"event":"task.cleaned_up","task":"m-fix"}\n{"ts":%s,"event":"task.dispatched","task":"m-fix","model":"qwen","harness":"pi"}\n{"ts":%s,"event":"task.merged","task":"m-fix","pr":"https://github.com/acme/alpha/pull/13"}\n{"ts":%s,"event":"task.dispatched","task":"m-fix","model":"opus","harness":"claude"}\n{"ts":%s,"event":"task.dispatched","task":"m-ready","model":"qwen"}\n' "$((now - 500))" "$((now - 130))" "$((now - 30))" "$((now - 10))" "$((now - 20))" >> "$home/state/fleet-ledger.jsonl"
  fm_write_meta "$home/state/m-fix.meta" "kind=ship" "project=alpha"
  printf 'working [at=%s] [key=nm-renew-review]: PR https://github.com/acme/alpha/pull/99\n' "$now" > "$home/state/m-fix.status"
  build "$home"
  jq -e --argjson now "$now" '.cycle_p50 == 2000 and .landed[-1] == 12 and ([.cards[] | select(.task == "m-gitlab" or .task == "m-gerrit" or .task == "z-lab" or .task == "z-review") | .stage] == ["landed","landed","landed","landed"]) and any(.cards[]; .task == "m-ready" and .stage == "queued" and .model == null and .started == null) and any(.cards[]; .pr == "https://github.com/acme/alpha/pull/13" and .model == "qwen" and .tool == "pi" and .started == $now - 130) and any(.homes[]; .id == "zephyrine" and .known == false and .ready == null) and any(.cards[]; .home == "zephyrine" and .stage == "landed" and .model == null and .started == null) and ([.cards[].id] | length == (unique | length)) and ([.cards[] | select(.task == "m-fix" and .stage == "landed")] | length == 2) and any(.cards[]; .id == "main/m-fix" and .stage == "review" and .started == $now - 10 and .model == "opus")' "$d/board.json" >/dev/null || fail "remote dispatch or renewed card identity was misrepresented"
  rm "$home/state/m-gitlab.meta" "$home/state/m-gerrit.meta"
  build "$home"
  jq -e '.landed[-1] == 12 and ([.cards[] | select(.task == "m-gitlab" or .task == "m-gerrit")] | length == 2)' "$d/board.json" >/dev/null || fail "cleanup lost forge landings"
  cp -R "$ROOT/bin/fm-dashboard" "$home/ui"
  printf '{"type":"module"}\n' > "$home/ui/package.json"
  node --input-type=module - "$home/ui" <<'JS' || fail "dashboard UI behavior regressed"
import assert from 'node:assert/strict'
const root = process.argv[2], ui = await import(`${root}/ui.js`), board = await import(`${root}/board.js`)
const d = { homes: [{ id: 'main', known: true, ready: 0 }, { id: 'remote', known: false, ready: null }], cards: [] }
assert.equal(ui.total(d, 0), '≥0'); assert.equal(ui.total(d, 0, 'queued'), '≥0'); assert.equal(ui.total(d, 0, 'landed'), '≥0')
assert.equal(ui.total(d, 2, 'active', 'main'), 2)
assert.equal(ui.prNum('https://gitlab.example/team/nested/app/-/merge_requests/27'), '27'); assert.equal(ui.prNum('https://github.com/team/app/pull/28'), '28'); assert.equal(ui.prNum('https://review.example/c/team/app/+/27'), '27')
const note = text => ({ verb: 'Waiting', stage: 'review', text, at: 1 })
const prefix = 'Waiting for approval of the production deployment configuration in '
assert.equal(board.squash([note(prefix + 'production'), note(prefix + 'staging')]).length, 2)
assert.equal(board.squash([note(prefix), { ...note(prefix), stage: 'ci' }]).length, 2)
assert.equal(board.squash([note(prefix), { ...note(prefix), at: 2 }])[0].n, 2)
assert.equal(board.stageTimes({ ci: 100, test: 200 }, 2, false)[2], null)
assert.equal(board.stageTimes({ building: 100, review: 200, test: 300 }, 2, false)[1], 100)
const c = { id: 'main/m-test', home: 'main', task: 'm-test', title: 'Test', stage: 'review', wait: 'waiting', why: 'm-login is complete; waiting for vendor credentials', history: [] }
assert.equal(ui.reason(c), c.why); assert.equal(ui.stuck({ ...c, wait: 'blocked' }), true)
let opened = null
const open = id => opened = id, desktop = board.Card({ d, c, open })
assert.equal(desktop.props.role, 'button')
for (const key of ['Enter', ' ']) { opened = null; let prevented = false; desktop.props.onKeyDown({ key, target: desktop, currentTarget: desktop, preventDefault() { prevented = true } }); assert.equal(opened, c.id); assert.equal(prevented, true) }
class El {
  constructor(name, type = 1) { Object.assign(this, { localName: name, nodeType: type, data: '', childNodes: [], parentNode: null, attrs: {}, listeners: {}, style: { setProperty() {}, removeProperty() {} }, onclick: null, onkeydown: null }) }
  get firstChild() { return this.childNodes[0] ?? null }
  get nextSibling() { const s = this.parentNode?.childNodes ?? []; return s[s.indexOf(this) + 1] ?? null }
  get textContent() { return this.nodeType === 3 ? this.data : this.childNodes.map(n => n.textContent).join('') }
  insertBefore(n, ref) { n.parentNode?.removeChild(n); n.parentNode = this; const i = this.childNodes.indexOf(ref); this.childNodes.splice(i < 0 ? this.childNodes.length : i, 0, n); return n }
  appendChild(n) { return this.insertBefore(n, null) }
  removeChild(n) { this.childNodes.splice(this.childNodes.indexOf(n), 1); n.parentNode = null; return n }
  setAttribute(k, v) { this.attrs[k] = String(v) }
  removeAttribute(k) { delete this.attrs[k] }
  addEventListener(t, f) { this.listeners[t] = f }
  removeEventListener(t) { delete this.listeners[t] }
}
globalThis.document = { createElement: n => new El(n), createElementNS: (_, n) => new El(n), createTextNode: s => Object.assign(new El('#text', 3), { data: String(s) }) }
const all = (n, p, out = []) => { if (p(n)) out.push(n); n.childNodes.forEach(k => all(k, p, out)); return out }
const hasClass = (n, k) => (n.attrs.class ?? n.className ?? '').split(' ').includes(k)
const { html, render } = await import(`${root}/vendor/preact-htm-3.1.1.js`)
const phone = [
  { id: 'main/a', home: 'main', task: 'a', title: 'Alpha', stage: 'building', history: [] },
  { id: 'main/b', home: 'main', task: 'b', title: 'Bravo', stage: 'building', history: [] },
  { id: 'main/c', home: 'main', task: 'c', title: 'Charlie', stage: 'review', wait: 'blocked', why: 'waiting on credentials', history: [] },
]
const pd = { homes: [{ id: 'main', name: 'Main', known: true, ready: 0 }], cards: phone }
let phoneOpened = null
const screen = new El('div')
render(html`<${board.MobileKanban} d=${pd} cards=${phone} r=${{ tab: 'active' }} open=${id => phoneOpened = id}/>`, screen)
assert.deepEqual(all(screen, n => n.attrs.role === 'tab').map(n => n.textContent), ['Building2', 'Review1'])
const cols = all(screen, n => hasClass(n, 'mcol'))
assert.deepEqual(cols.map(col => all(col, n => n.attrs['data-card']).map(n => n.attrs['data-card'])), [['main/a', 'main/b'], ['main/c']])
assert.deepEqual(cols.map(col => all(col, n => hasClass(n, 'n'))[0].textContent), ['2', '1'])
const bravo = all(screen, n => n.attrs['data-card'] === 'main/b')[0]
bravo.listeners.click.call(bravo, { type: 'click' }); assert.equal(phoneOpened, 'main/b')
phoneOpened = null; bravo.listeners.keydown.call(bravo, { type: 'keydown', key: 'Enter', target: bravo, currentTarget: bravo, preventDefault() {} }); assert.equal(phoneOpened, 'main/b')
JS
  jq -e '.flow.limitations > 0 and .flow.time_to_merge.unknown == 0 and (.flow.executed_7d | length) == 1' "$d/board.json" >/dev/null || fail "unavailable remote records became ghost observations"
  jq -e --arg h "$home" '[.. | strings | select(contains($h) or contains("/home/") or contains("/Users/") or contains("/tmp/"))] | length == 0' "$d/board.json" >/dev/null || fail "board.json carries host paths: $(jq -c --arg h "$home" '[.. | strings | select(contains($h) or contains("/home/") or contains("/Users/") or contains("/tmp/"))]' "$d/board.json" | cut -c1-300)"
  jq -e '[.. | objects | keys[] | select(. == "reason" or . == "source" or . == "gate_source" or . == "errors")] | length == 0' "$d/board.json" >/dev/null || fail "board.json carries raw reason, source, gate_source or errors keys: $(jq -c '[.. | objects | keys[] | select(. == "reason" or . == "source" or . == "gate_source" or . == "errors")]' "$d/board.json" | cut -c1-300)"
  jq -e '[.. | strings | select(test("\\[(at|key)="))] | length == 0' "$d/board.json" >/dev/null || fail "board.json carries raw status-line tokens: $(jq -c '[.. | strings | select(test("\\[(at|key)="))]' "$d/board.json" | cut -c1-300)"
  pass "board.json carries no host paths, raw reason keys or status-line tokens, and carries stages, waits, ask list and shipped flow observations; known durations, unknown lifecycle splits, queue why-lines and read-only capacity remain distinct"
}

test_ship_view_loads_against_the_app() {
  command -v node >/dev/null 2>&1 || { echo "skip: node not found for the Ship tab modules"; return 0; }
  local got
  # Loading links every name the Ship tab takes from the app's helpers and three.js; a renamed helper fails here.
  got=$(cd "$ROOT/bin/fm-dashboard" && node --input-type=module -e "
const ship = await import('./ship/index.js'), scene = await import('./ship/scene.js')
console.log(typeof ship.mount, typeof scene.world)" 2>&1) || fail "the Ship tab modules did not load: $got"
  [ "$got" = "function function" ] || fail "the Ship tab modules lack mount or world: $got"
  pass "the Ship tab's modules load against the app's helpers and export mount and world"
}

test_fleet_past_twenty_mates_keeps_every_lead_row() {
  local home d i mdir
  home=$(make_home many)
  d="$home/state/dashboard"
  # Mate homes live outside the active home; each reads its own summary, one row each:
  # mate24's is an hour old and Main's view says mate25 is not running.
  now=$(date +%s)
  for i in $(seq -w 1 25); do
    mdir="$TMP_ROOT/mate$i"
    mkdir -p "$mdir/state" "$mdir/data"
    printf -- '- mate%s - domain %s (home: %s; scope: work; projects: alpha; added 2026-07-11)\n' \
      "$i" "$i" "$mdir" >> "$home/data/secondmates.md"
    summary "$mdir" unknown "$([ "$i" = 24 ] && echo $((now - 3600)) || echo "$now")"
  done
  summary "$home" no_active_work "$now" '"endpoints":[{"id":"mate25","endpoint":{"exists":false}}]'
  build "$home"
  has "$d/index.html" "✕ 1 lead down" "mate24 Silent 1 h" "mate25 Not running"
  python3 - "$d/index.html" <<'PY' || fail "a mate past the twentieth lost its lead state"
import html, re, sys
homes = open(sys.argv[1]).read().split('<div class="hrs">', 1)[1]
text = re.sub(r'\s+', ' ', html.unescape(re.sub(r'<[^>]+>', ' ', homes)))
for mate in ('mate01', 'mate23'):
    i = text.find(mate)
    assert i >= 0, mate
    assert 'Runtime unknown' in text[i:i + 200], text[i:i + 200]
PY
  pass "a fleet past twenty mates keeps every lead row"
}

test_review_evidence_boundaries() {
  local home d z now today key old
  home=$(make_home review)
  d="$home/state/dashboard" z="$home/mates/zephyrine"
  now=$(date +%s) today=$(date +%F) old=$(iso 1)
  printf 'backend = "markdown"\n[markdown]\narchive = "data/custom-done.md"\n' > "$home/.tasks.toml"
  printf -- '- [x] archived - Archived completion (done %s)\n' "$today" > "$home/data/custom-done.md"
  lane "$home" m-ci ship "blocked [at=$now] [key=checks]: CI failed: approve config/release.json instead of config/staging.json https://github.com/acme/alpha/pull/22"
  python3 - "$home/data/backlog.md" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace('needs his call', 'Approve config/release.json instead of config/staging.json'))
PY
  summary "$home" no_active_work "$((now - 3600))" '"endpoints":[{"id":"zephyrine","endpoint":{"exists":false}}]'
  rm "$home/state/zephyrine.status"
  mkdir "$home/state/zephyrine.status"
  build "$home"
  has "$d/index.html" "Closed 7 d 3" "Landed today at least 1" "Recorded merges only; some may be missing." "In: filed, always at least" \
    "CI failed: approve release.json instead of staging.json PR 22"
  lacks "$d/index.html" "Not running" "lead down" "config/release.json" "https://github.com/acme/alpha/pull/22" "Landed today 1"
  for p in backlog backlog.home; do
    has "$d/$p.html" "CI failed: approve release.json instead of staging.json PR 22" "Approve release.json instead of staging.json"
    lacks "$d/$p.html" "config/release.json" "[key=checks]"
  done
  has "$d/measure.html" "always at least: recording can be disabled" "always at least: items filed and closed between readings"
  jq '.providers = [{provider:"cursor",state:{status:"fresh"},windows:[{percentUsed:80,resetsAt:"2030-01-01T00:00:00Z"}]},{provider:"copilot",state:{status:"auth_required"}}]' "$home/quota.json" > "$home/.cache/quota-axi/quotas.json"
  build "$home"
  has "$d/index.html" "Quota runs out unknown" "Cursor unknown" "Copilot unknown"
  lacks "$d/index.html" "Quota runs out none" "lasts"
  jq --arg old "$old" --arg reset "$(iso -10)" '.providers = [(.providers[0] + {label:"Codex · work"} | .state.refreshedAt=$old), (.providers[0] + {label:"Codex · personal"} | .windows=[(.windows[0] + {percentUsed:0}),(.windows[0] + {percentUsed:80,windowSeconds:360000,resetsAt:$reset})])]' "$home/quota.json" > "$home/.cache/quota-axi/quotas.json"
  build "$home"
  has "$d/index.html" "Codex · work before its reset" "Codex · work out" "Codex · personal resets" "across accounts"
  jq -e --arg old "$old" '.metrics.quota.read_at == ($old | fromdateiso8601) and .metrics.quota.read_at_latest > .metrics.quota.read_at and .quota_accounts[1].limit == null and .quota_accounts[1].status == "through_reset"' "$d/data.json" >/dev/null || fail "quota limits or aggregate source times are wrong"
  grep -q 'Codex · personal</span>.*width:80%' "$d/index.html" || fail "quota bar hid the most-used non-exhausting window"
  grep -q "Codex · work before its reset · as of .*$(date -d "$old" '+%H:%M')" "$d/index.html" || fail "headline used the cache time instead of the limiting account time"
  summary "$home" no_active_work "$now" '"endpoints":[]'
  printf '{"result":{"agents":[]}}\n' > "$home/herdr.json"
  build "$home"
  has "$d/index.html" "zephyrine Runtime unknown"
  lacks "$d/index.html" "lead down"
  summary "$home" no_active_work "$now" '"endpoints":[{"id":"zephyrine","endpoint":{"exists":false}}]'
  build "$home"
  has "$d/index.html" "zephyrine Not running" "lead down"
  printf -- '- zephyrine - remote (host: distant; root: /srv; home: %s; scope: work; projects: alpha; added 2026-07-11)\n' "$z" > "$home/data/secondmates.md"
  key=$(printf 'zephyrine\ndistant\n%s\n' "$z" | sha256sum | cut -d' ' -f1)
  mkdir "$home/state/secondmate-summary-cache"
  jq '.state="externally_held" | .hold_classifier_schema="fm-captain-hold-buckets.v1"' "$z/state/home-summary.json" > "$home/state/secondmate-summary-cache/$key.json"
  build "$home"
  has "$d/index.html" "zephyrine Waiting on someone else" "Closed 7 d unknown" "Out: unknown"
  lacks "$d/index.html" "Not running" "Start the zephyrine thing" "Ship the zephyrine thing"
  rm "$home/state/secondmate-summary-cache/$key.json"
  build "$home"
  has "$d/index.html" "zephyrine State unknown"
  printf 'backend = "beads"\n' > "$home/.tasks.toml"
  build "$home"
  has "$d/index.html" "Closed 7 d unknown" "Out: unknown"
  [ ! -e "$home/quota.called" ] || fail "page build collected quota"
  rm "$home/.tasks.toml"
  printf -- '- zephyrine - domain (home: %s; scope: work; projects: alpha; added 2026-07-11)\n' "$z" > "$home/data/secondmates.md"
  printf '\n## Queued\n- [ ] m-held - Lead release call (hold: choose lead release) (hold-kind: captain)\n' >> "$z/data/backlog.md"
  printf '\n## In flight\n- [ ] flight-call - Flight call (hold: choose flight scope) (hold-kind: captain)\n\n## Queued\n- [ ] expired-call - Expired call (hold: choose deferred scope) (hold-kind: captain) (hold-until: %s)\n- [ ] vendor - Vendor access (since %s) (hold: waiting for vendor credentials) (hold-kind: external)\n' "$(date -d yesterday +%F)" "$today" >> "$home/data/backlog.md"
  build "$home"
  has "$d/index.html" "4 held for triage" "Captain calls and queued holds 5"
  for p in backlog backlog.home; do has "$d/$p.html" "5 items held" "Held for the captain: 4"; done
  for p in index backlog backlog.home; do has "$d/$p.html" "waiting for vendor credentials" "choose flight scope" "choose deferred scope" "Wait for the captain's call" "Approve release.json instead of staging.json" "Lead release call" "choose lead release"; done
  jq -e '(.held_items | length) == 5 and .metrics.held_for_captain.value == 4 and .metrics.queue.value.held == 3 and ([.held_items[] | [.home, .title]] | unique | length) == 5 and any(.held_items[]; .home == "main" and .title == "Wait for the captain\u0027s call") and any(.held_items[]; .home == "zephyrine" and .title == "Lead release call")' "$d/data.json" >/dev/null || fail "home-scoped hold union lost calls or double-counted items"
  pass "dashboard preserves lower bounds, route ownership, configured archives, runway uncertainty and wait reasons"
}

test_incomplete_lanes_and_moved_filings() {
  local home d z before after now real_tasks
  home=$(make_home coverage)
  d="$home/state/dashboard" z="$home/mates/zephyrine" now=$(date +%s)
  lane "$home" m-ci ship "blocked [at=$now]: CI evidence=/home/u/x/report.md ref:https://github.com/acme/alpha/pull/22"
  build "$home"
  before=$(jq '.metrics.filed.daily[-1].value' "$d/data.json")
  tasks-axi mv m-ready m-after --file "$home/data/backlog.md" --to "$z/data/backlog.md" >/dev/null || fail "task move failed"
  build "$home"
  after=$(jq '.metrics.filed.daily[-1].value' "$d/data.json")
  [ "$before" = "$after" ] || fail "moving tasks overcounted filings: $before -> $after"
  has "$d/index.html" "evidence=report.md ref:PR 22"
  lacks "$d/index.html" "evidence=/home/u" "ref:https://"
  FM_HOME="$home" bash "$ROOT/bin/fm-tasks-axi.sh" list --limit 10000 --fields held,hold_kind,hold_reason,blocked,created,closed > "$home/backend.toon" || fail "backlog fixture failed"
  printf 'backend = "beads"\n' > "$home/.tasks.toml"
  real_tasks=$(command -v tasks-axi)
  # shellcheck disable=SC2016 # the single-quoted stub expands when it runs
  printf '#!/bin/sh\n[ "$PWD" = "%s" ] || exec "%s" "$@"\n[ -z "${TASKS_AXI_FILE:-}" ] || exit 1\necho called > "%s/backend.called"\ncat "%s/backend.toon"\n' "$home" "$real_tasks" "$home" "$home" > "$home/stubs/tasks-axi"
  chmod +x "$home/stubs/tasks-axi"
  build "$home"
  [ -e "$home/backend.called" ] || fail "non-markdown listing was skipped"
  has "$d/backlog.html" "Wait for the captain's call" "needs his call"
  jq -e '.metrics.ready.status == "exact" and .metrics.closed.status == "unknown"' "$d/data.json" >/dev/null || fail "backend coverage was lost"
  rm "$home/.tasks.toml" "$home/stubs/tasks-axi"
  mkdir -p "$home/mates/missing/data"
  printf '## Queued\n- [ ] missing-ready - Missing home ready (since %s)\n' "$(date +%F)" > "$home/mates/missing/data/backlog.md"
  printf -- '- missing - domain (home: %s; scope: work; projects: alpha; added 2026-07-11)\n' "$home/mates/missing" >> "$home/data/secondmates.md"
  build "$home"
  has "$d/index.html" "Lanes open at least 8" "Stuck at least 3" "free unknown" "Ready, capacity unknown 1" "unknown of 3"
  lacks "$d/index.html" "All flowing" "missing 0 of 3"
  has "$d/backlog.html" "at least 8 lanes open" "Fleet at least 8" "missing unknown 3"
  for p in backlog backlog.home; do has "$d/$p.html" "Oldest validation or CI wait: unknown"; done
  has "$d/backlog.home.html" "missing unknown"
  jq -e '.metrics.lanes.status == "lower_bound" and .metrics.stuck.status == "lower_bound" and .metrics.stuck.value == 3 and .metrics.free_lanes.status == "unknown" and ([.homes[] | select(.home == "missing")][0].lanes.value == null)' "$d/data.json" >/dev/null || fail "missing lane coverage looks exact"
  printf '%s\tlocal-pressure-task\tlocal pressure refusal\n' "$now" > "$z/state/admission-refused"
  build "$home"
  has "$d/index.html" "new agents wait (zephyrine)" "local-pressure-task"
  printf '%s\tmain-pressure-task\tmain pressure refusal\n' "$now" > "$home/state/admission-refused"
  printf -- '- zephyrine - remote (host: distant; root: /srv; home: %s; scope: work; projects: alpha; added 2026-07-11)\n' "$z" > "$home/data/secondmates.md"
  build "$home"
  has "$d/index.html" "new agents wait (Main)" "main-pressure-task"
  for p in index backlog backlog.home measure; do
    lacks "$d/$p.html" "new agents wait (zephyrine)" "local-pressure-task" "local pressure refusal"
  done
  has "$d/index.html" "Lanes open at least 7" "unknown of 3"
  jq -e '[.homes[] | select(.home == "zephyrine")][0] | .lanes.status == "unknown" and .free_lanes.value == null' "$d/data.json" >/dev/null || fail "remote lane capacity was inferred"
  : > "$home/data/secondmates.md"
  printf '## Queued\n' > "$home/data/backlog.md"
  rm "$home/state"/m-*.meta "$home/state"/m-*.status
  mkdir "$home/state/unreadable.meta"
  build "$home"
  has "$d/index.html" "Lanes open at least 0" "free unknown"
  lacks "$d/index.html" "All flowing" "Ready, a lane is free 1"
  for p in backlog backlog.home; do
    has "$d/$p.html" "Oldest validation or CI wait: unknown"
    lacks "$d/$p.html" "none running"
  done
  pass "moved filings count once and unavailable lanes retain unknown capacity across HTML and JSON"
}

test_new_lane_and_unwritten_archive_stay_exact() {
  local home d before
  home=$(make_home fresh)
  d="$home/state/dashboard"
  printf 'backend = "markdown"\n[markdown]\narchive = "data/custom-done.md"\n' > "$home/.tasks.toml"
  build "$home"
  before=$(jq '.metrics.lanes.value' "$d/data.json")
  fm_write_meta "$home/state/m-new.meta" "kind=ship" "project=alpha" "herdr_pane_id=pane-m-new"
  build "$home"
  jq -e --argjson n "$((before + 1))" '.metrics.lanes.value == $n and .metrics.lanes.status == "exact" and .metrics.closed.status == "exact" and .metrics.closed.value > 0' "$d/data.json" >/dev/null ||
    fail "a lane with no status line or an archive not yet written made a number unknown: $(jq -c '.metrics.lanes, .metrics.closed | del(.daily)' "$d/data.json")"
  has "$d/index.html" "Closed 7 d 2"
  mkfifo "$home/state/m-vanishing.meta"
  # Unlink while the writer is open, so the reader cannot reach EOF before removal.
  python3 - "$home/state/m-vanishing.meta" <<'PY' &
import os, sys
with open(sys.argv[1], 'w') as fh:
    os.unlink(sys.argv[1])
    fh.write('kind=ship\nproject=alpha\n')
PY
  local writer=$!
  build "$home"
  wait "$writer" || fail "vanishing metadata fixture failed"
  jq -e --argjson n "$((before + 1))" '.metrics.lanes.value == $n and .metrics.lanes.status == "exact"' "$d/data.json" >/dev/null || fail "vanished lane aborted or polluted the build"
  pass "a lane with no status line yet and an archive not yet written keep their numbers exact"
}

test_unavailable_readings_and_concurrent_caches() {
  local home d
  home=$(make_home sources)
  d="$home/state/dashboard"
  : > "$home/data/secondmates.md"
  printf '## Queued\n' > "$home/data/backlog.md"
  rm "$home/state"/m-*.meta "$home/state"/m-*.status
  printf '{"result":{"agents":[]}}\n' > "$home/herdr.json"
  build "$home"
  has "$d/index.html" "All flowing"
  has "$d/measure.html" "Every source was read."
  jq '.providers = [{provider:"cursor",state:{status:"fresh"}}]' "$home/.cache/quota-axi/quotas.json" > "$home/q.json"
  mv "$home/q.json" "$home/.cache/quota-axi/quotas.json"
  build "$home"
  lacks "$d/index.html" "All flowing"
  lacks "$d/measure.html" "Every source was read."
  jq -e 'any(.sources_unknown[]; .source == "quota-axi account" and (.reason | contains("Cursor: runway unknown")))' "$d/data.json" >/dev/null || fail "missing account runway source"
  cp "$home/quota.json" "$home/.cache/quota-axi/quotas.json"
  rm "$home/proc/meminfo" "$home/proc/pressure/memory" "$home/proc/locks"
  printf '#!/bin/sh\necho unavailable >&2\nexit 2\n' | tee "$home/stubs/adb" "$home/stubs/pgrep" > "$home/stubs/systemctl"
  build "$home"
  lacks "$d/index.html" "All flowing"
  lacks "$d/measure.html" "Every source was read."
  jq -e '[.sources_unknown[].source] | contains(["machine free memory","machine memory pressure","machine Gradle builds","machine heavy jobs","machine heavy high limit","machine heavy max limit","devices"])' "$d/data.json" >/dev/null || fail "unavailable readings missing from source list"
  home=$(make_home leads)
  d="$home/state/dashboard"
  for scenario in invalid future runtime missing; do
    summary "$home/mates/zephyrine" active_child_work "$(date +%s)"
    summary "$home" no_active_work "$(date +%s)" '"endpoints":[{"id":"zephyrine","endpoint":{"exists":true,"agent_alive":"alive"}}]'
    case "$scenario" in
      invalid) summary "$home/mates/zephyrine" active_child_work "$(date +%s)" '"valid":false' ;;
      future) summary "$home/mates/zephyrine" active_child_work "$(( $(date +%s) + 3600 ))" ;;
      runtime) summary "$home" no_active_work "$(date +%s)" '"endpoints":[]'; printf '{"result":{"agents":[]}}\n' > "$home/herdr.json" ;;
      missing) rm "$home/mates/zephyrine/state/home-summary.json" ;;
    esac
    build "$home"
    lacks "$d/measure.html" "Every source was read."
    jq -e 'any(.sources_unknown[]; .source == "lead state" and (.reason | startswith("zephyrine:")))' "$d/data.json" >/dev/null || fail "lead uncertainty absent: $scenario"
  done
  home=$(make_home concurrent)
  : > "$home/data/secondmates.md"
  FM_HOME="$home" bash "$ROOT/bin/fm-tasks-axi.sh" list --limit 10000 --fields held,hold_kind,hold_reason,blocked,created,closed > "$home/table"
  # shellcheck disable=SC2016 # the single-quoted stub expands when it runs
  printf '#!/bin/sh\ncat "$TEST_TABLE"\ntouch "$TEST_TABLE.read"\n' > "$home/stubs/tasks-axi"
  chmod +x "$home/stubs/tasks-axi"
  python3 - "$home" "$DASH" <<'PY' || fail "concurrent cache updates lost observations or escaped the lock"
import fcntl, json, os, pathlib, subprocess, sys, time
home, dash = pathlib.Path(sys.argv[1]), sys.argv[2]
state = home / 'state/dashboard'
original = (state / 'history.tsv').read_text()
env = dict(os.environ, PATH=str(home / 'stubs') + ':' + os.environ['PATH'], FM_HOME=str(home), HOME=str(home), FM_DEVICE_LOCK_DIR=str(home / 'locks'), FM_DASHBOARD_PROC=str(home / 'proc'), FM_MAC_HOST='')
processes = []
with (state / '.cache.lock').open('a') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    try:
        for name in ('a-ready', 'b-ready'):
            table = home / name
            table.write_text((home / 'table').read_text().replace('m-ready', name))
            processes.append(subprocess.Popen([dash, 'build'], env=dict(env, TEST_TABLE=str(table)), stdout=subprocess.PIPE, stderr=subprocess.PIPE))
        deadline = time.monotonic() + 30
        while not all((home / (n + '.read')).exists() for n in ('a-ready', 'b-ready')):
            assert time.monotonic() < deadline, 'backlog reads stalled'
            time.sleep(.05)
        for p in processes:
            try: p.wait(timeout=.3)
            except subprocess.TimeoutExpired: pass
            else: raise AssertionError('build did not wait for cache lock')
        assert not (state / 'filed.json').exists()
        assert (state / 'history.tsv').read_text() == original
    finally:
        fcntl.flock(lock, fcntl.LOCK_UN)
        for p in processes:
            out, err = p.communicate(timeout=30)
            assert p.returncode == 0, err.decode()
items = json.loads((state / 'filed.json').read_text())['items']
assert {'main\ta-ready', 'main\tb-ready'} <= items.keys(), items
history = [list(map(int, l.split())) for l in (state / 'history.tsv').read_text().splitlines()]
assert len(history) == 2 and all(len(r) == 4 for r in history), history
assert not list(state.glob('*.tmp.*'))
assert json.loads((state / 'data.json').read_text())['metrics']['lanes']['value'] == 7
PY
  pass "unavailable displayed readings suppress reassurance and concurrent cache updates preserve both builds"
}

test_ci_failures_remain_stuck_in_metrics() {
  local home d now
  home=$(make_home ci-stuck)
  d="$home/state/dashboard" now=$(date +%s)
  lane "$home" m-stuck ship "blocked [at=$now]: CI needs credentials"
  lane "$home" m-resume ship "failed [at=$now]: no-mistakes checks failed"
  build "$home"
  python3 - "$d" <<'PY' || fail "CI failures disagree between board and metrics"
import json, pathlib, sys
out = pathlib.Path(sys.argv[1])
metrics = json.loads((out / 'data.json').read_text())
board = json.loads((out / 'board.json').read_text())
cards = {c['task']: c for c in board['cards'] if c.get('task')}
assert cards['m-stuck']['wait'] == cards['m-resume']['wait'] == 'blocked'
assert metrics['metrics']['stuck']['value'] == 3, metrics['metrics']['stuck']
assert metrics['metrics']['stuck']['value'] == sum(c.get('wait') in ('blocked', 'decision') for c in board['cards'])
states = metrics['metrics']['lane_states']['value']
assert states['blocked'] == 2, states
assert states['validating'] == 1, states
PY
  has "$d/index.html" 'Stuck 3' '2 blocked'
  lane "$home" m-held-ci ship "paused [at=$now]: waiting for CI checks" \
    "needs-decision [at=$now] [key=captain-hold-ci]: captain parked CI"
  build "$home"
  python3 - "$d" <<'PY' || fail "captain-held lane disagrees between board and metrics"
import json, pathlib, sys
out = pathlib.Path(sys.argv[1])
metrics = json.loads((out / 'data.json').read_text())['metrics']
board = json.loads((out / 'board.json').read_text())
held = next(c for c in board['cards'] if c.get('task') == 'm-held-ci')
assert held['wait'] == 'parked', held
assert metrics['stuck']['value'] == 3, metrics['stuck']
assert metrics['stuck']['value'] == sum(c.get('wait') in ('blocked', 'decision') for c in board['cards'])
assert metrics['lanes']['value'] == sum(metrics['lane_states']['value'].values()) == 9
PY
  has "$d/index.html" 'Stuck 3' '2 blocked'
  printf 'resolved [at=%s] [key=captain-hold-ci]: captain released CI\nfailed [at=%s]: CI checks failed\n' "$now" "$now" >> "$home/state/m-held-ci.status"
  build "$home"
  python3 - "$d" <<'PY' || fail "released CI failure was not counted as stuck"
import json, pathlib, sys
out = pathlib.Path(sys.argv[1])
metrics = json.loads((out / 'data.json').read_text())['metrics']
board = json.loads((out / 'board.json').read_text())
released = next(c for c in board['cards'] if c.get('task') == 'm-held-ci')
assert released['wait'] == 'blocked', released
assert metrics['stuck']['value'] == 4, metrics['stuck']
assert metrics['stuck']['value'] == sum(c.get('wait') in ('blocked', 'decision') for c in board['cards'])
PY
  has "$d/index.html" 'Stuck 4' '3 blocked'
  pass "CI failures stay stuck unless captain-held, and releasing the hold restores the count"
}

if [ "${1:-}" = ci-stuck ]; then test_ci_failures_remain_stuck_in_metrics; exit; fi
if [ "${1:-}" = board ]; then test_board_json_feeds_the_app; exit; fi
if [ "${1:-}" = review ]; then test_board_json_feeds_the_app; test_serve_answers_each_page_and_remembers_the_grouping; exit; fi

test_ci_failures_remain_stuck_in_metrics
test_unavailable_readings_and_concurrent_caches
test_new_lane_and_unwritten_archive_stay_exact
test_incomplete_lanes_and_moved_filings
test_review_evidence_boundaries
test_overview_answers_the_four_questions_with_sums_that_add_up
test_backlog_and_method_pages_show_their_numbers
test_fleet_past_twenty_mates_keeps_every_lead_row
test_board_json_feeds_the_app
test_ship_view_loads_against_the_app
test_each_failed_source_shows_unknown_and_why
test_devices_and_machine_come_from_read_only_probes
test_serve_answers_each_page_and_remembers_the_grouping
