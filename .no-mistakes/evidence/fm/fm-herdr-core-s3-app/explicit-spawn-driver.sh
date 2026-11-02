#!/usr/bin/env bash
set -u
. .live/env.sh
: > "$EVIDENCE/explicit-spawns.log"
for variant in flag environment config; do
  id="live$variant"
  mkdir -p "$FM_HOME/data/$id"
  printf "# Task\n## Captain's intent\nValidate explicit backend precedence.\n\n## Firstmate spec\nRun an isolated shell worker.\n" > "$FM_HOME/data/$id/brief.md"
  printf '\n=== %s ===\n' "$variant" >> "$EVIDENCE/explicit-spawns.log"
  case "$variant" in
    flag) FM_BACKEND=tmux bin/fm-spawn.sh "$id" "$ROOT/.live/project" "sh -c 'printf explicit-flag-worker-ok'" --mode no-mistakes --yolo off --backend hc >> "$EVIDENCE/explicit-spawns.log" 2>&1 ;;
    environment) FM_BACKEND=hc bin/fm-spawn.sh "$id" "$ROOT/.live/project" "sh -c 'printf explicit-env-worker-ok'" --mode no-mistakes --yolo off >> "$EVIDENCE/explicit-spawns.log" 2>&1 ;;
    config) printf 'hc\n' > "$FM_HOME/config/backend"; bin/fm-spawn.sh "$id" "$ROOT/.live/project" "sh -c 'printf explicit-config-worker-ok'" --mode no-mistakes --yolo off >> "$EVIDENCE/explicit-spawns.log" 2>&1 ;;
  esac
  rc=$?
  printf 'spawn_exit=%s\n' "$rc" >> "$EVIDENCE/explicit-spawns.log"
  [ "$rc" = 0 ] || { echo "$rc" > .live/explicit.rc; exit "$rc"; }
  cp "$FM_HOME/state/$id.meta" "$EVIDENCE/$id.meta"
  grep -q '^backend=hc$' "$FM_HOME/state/$id.meta" || exit 4
  if grep -q '^backend_detect=' "$FM_HOME/state/$id.meta"; then exit 5; fi
  address=$(awk -F= '$1=="hc_terminal" {print $2}' "$FM_HOME/state/$id.meta")
  lab get "$address" --json >> "$EVIDENCE/explicit-spawns.log"
  lab read "$address" --lines 12 >> "$EVIDENCE/explicit-spawns.log"
  bin/fm-teardown.sh "$id" >> "$EVIDENCE/explicit-spawns.log" 2>&1 || exit 6
  rm -f "$FM_HOME/config/backend"
done
printf '0\n' > .live/explicit.rc
