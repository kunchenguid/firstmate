#!/usr/bin/env bash
set -eu
ROOT=$PWD
E=~/.no-mistakes/evidence/01M6C5V0SWVRT0HZHREZ8XYXVM
LAB=$ROOT/.live-validation/spawn-home
bin/fm-lab-home.sh create "$LAB"
SOCKET_DIR=$(bin/fm-lab-home.sh tmux-dir "$LAB")
cleanup() {
  TMUX_TMPDIR="$SOCKET_DIR" tmux -L fm-lab kill-server 2>/dev/null || true
  bin/fm-lab-home.sh teardown "$LAB"
}
trap cleanup EXIT
mkdir -p "$LAB/project"
git -C "$LAB/project" init -q -b main
git -C "$LAB/project" -c user.name='Local validation' -c user.email='validation@example.test' commit --allow-empty -qm 'Disposable spawn project'
export FM_HOME="$LAB" TREEHOUSE_ROOT="$LAB/pool" TMUX_TMPDIR="$SOCKET_DIR"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
# The shell is a disposable command launcher, not an impersonated agent/primary.
env -u NO_MISTAKES_GATE tmux -L fm-lab new-session -d -s launch -c "$ROOT" -x 120 -y 40 -e FM_HOME="$LAB" -e TREEHOUSE_ROOT="$LAB/pool" -e TERM_PROGRAM=ghostty 'bash --noprofile --norc'
TMUX=$(tmux -L fm-lab display-message -p -t launch '#{socket_path},#{pid},0')
export TMUX
printf 'invalid-value\n' > "$LAB/config/osc7501-status"
for n in 1 2; do
  id=raw-live-$n
  mkdir -p "$LAB/data/$id"
  printf "# Task\n## Captain's intent\nRun a disposable local workload.\n\n## Firstmate spec\nPrint proof of execution and stop.\n" > "$LAB/data/$id/brief.md"
  touch "$LAB/state/.last-watcher-beat"
  if [ "$n" = 1 ]; then
    raw="printf 'RAW-LIVE-1-RAN\\n';"
  else
    raw="printf 'RAW-LIVE-2-RAN\\n' # trailing comment"
  fi
  echo "=== fm-spawn raw case $n ==="
  bin/fm-spawn.sh "$id" "$LAB/project" --scout --backend tmux "$raw"
  target=$(awk -F= '$1=="window" {print substr($0,8)}' "$LAB/state/$id.meta")
  sleep 2
  tmux -L fm-lab capture-pane -p -t "$target" > "$E/spawn-raw-$n.txt"
  grep -q "RAW-LIVE-$n-RAN" "$E/spawn-raw-$n.txt"
  if [ "$n" = 1 ]; then grep -q 'unknown value; using off' "$E/spawn-raw-$n.txt"; fi
  cat "$E/spawn-raw-$n.txt"
done
