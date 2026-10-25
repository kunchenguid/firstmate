#!/usr/bin/env bash
# Integration test for the installed mover and its real proc/cgroup traversal using private fixtures.
set -euo pipefail
d=$(mktemp -d); trap 'rm -rf -- "$d"' EXIT
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
mkdir -p "$d/bin" "$d/home" "$d/config" "$d/data" "$d/herdr/child" "$d/heavy"
export HOME="$d/home" XDG_CONFIG_HOME="$d/config" XDG_DATA_HOME="$d/data" XDG_STATE_HOME="$d/state"
cat >"$d/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
STUB
chmod +x "$d/bin/systemctl"; export PATH="$d/bin:$PATH" SYSTEMCTL_LOG="$d/systemctl.log"
bash "$repo/host-memory/install.sh"
installed=$d/data/fm-host-memory/fm-heavy-adopt.sh
[ -x "$installed" ] || { echo 'FAIL mover not installed'; exit 1; }
grep -Fqx "ExecStart=$installed" "$d/config/systemd/user/fm-heavy-adopt.service"
grep -Fqx 'OnUnitActiveSec=20' "$d/config/systemd/user/fm-heavy-adopt.timer"
grep -Fqx -- '--user enable --now fm-heavy-adopt.timer' "$SYSTEMCTL_LOG"
# Previous sample is one interval old; PID 100 exceeded the measured 2 CPU-second threshold.
mkdir -p "$d/state/fm-host-memory"
specs=('100 yes 1 250' '101 worker 100 0' '102 node 100 250' '103 herdr 1 500' '104 java 1 0'
  '105 child 102 0' '106 no-mistakes 100 250' '107 task-child 106 0'
  '108 claude 100 250' '109 task-child 108 0' '110 pi 100 250' '111 task-child 110 0'
  '112 codex 100 250' '113 task-child 112 0' '114 opencode 100 250' '115 task-child 114 0'
  '116 cursor-agent 100 250' '117 task-child 116 0' '118 gemini 100 250' '119 task-child 118 0'
  '120 task-child 106 250')
for spec in "${specs[@]}"; do
  read -r pid name parent cpu <<<"$spec"
  born=$((1000 + pid))
  printf '%s %s 0\n' "$pid" "$born" >>"$d/state/fm-host-memory/fm-heavy-adopt.cpu"
  mkdir -p "$d/proc/$pid"
  printf '%s\n' "$name" >"$d/proc/$pid/comm"
  if [ "$pid" = 102 ]; then printf '/usr/bin/node\0/opt/codex.js\0' >"$d/proc/$pid/cmdline"
  else printf '/usr/bin/%s\0' "$name" >"$d/proc/$pid/cmdline"; fi
  printf 'Name:\t%s\nVmRSS:\t%s kB\n' "$name" "$([ "$pid" = 104 ] && echo 4000000 || echo 1000)" >"$d/proc/$pid/status"
  python3 - "$d/proc/$pid/stat" "$name" "$parent" "$cpu" "$born" <<'PY'
import sys
path, name, parent, cpu, born = sys.argv[1:]
fields = ['S', parent, *(['0'] * 9), cpu, '0', *(['0'] * 6), born]
open(path, 'w').write(f'{path.split("/")[-2]} ({name}) ' + ' '.join(fields) + '\n')
PY
done
printf '100\n103\n104\n' >"$d/herdr/cgroup.procs"
for spec in "${specs[@]}"; do pid=${spec%% *}; [ "$pid" = 100 ] || [ "$pid" = 103 ] || [ "$pid" = 104 ] || printf '%s\n' "$pid" >>"$d/herdr/child/cgroup.procs"; done
: >"$d/heavy/cgroup.procs"
FM_HEAVY_ADOPT_HERDR_CGROUP="$d/herdr" FM_HEAVY_ADOPT_PROC="$d/proc" FM_HEAVY_ADOPT_STATE="$d/state/fm-host-memory" FM_HEAVY_ADOPT_DEST="$d/heavy/cgroup.procs" "$installed"
for pid in 100 101 104 120; do grep -Fqx "$pid" "$d/heavy/cgroup.procs" || { echo "FAIL expected move $pid"; exit 1; }; done
for pid in 102 103 105 106 107 108 109 110 111 112 113 114 115 116 117 118 119; do
  if grep -Fqx "$pid" "$d/heavy/cgroup.procs"; then echo "FAIL protected process/tree moved: $pid"; exit 1; fi
done
bash "$repo/host-memory/uninstall.sh"
[ ! -e "$installed" ] && [ ! -e "$d/config/systemd/user/fm-heavy-adopt.service" ] && [ ! -e "$d/config/systemd/user/fm-heavy-adopt.timer" ] && [ ! -e "$d/state/fm-host-memory/fm-heavy-adopt.cpu" ] || { echo 'FAIL mover units/state not uninstalled'; exit 1; }
grep -Fqx -- '--user disable --now fm-heavy-adopt.timer' "$SYSTEMCTL_LOG"
echo 'PASS mover install, CPU descendants, agent/Herdr exclusion, memory rule and uninstall'
