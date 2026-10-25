#!/usr/bin/env bash
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
mkdir -p "$d/home/state" "$d/home/bin" "$d/stubs"
cat >"$d/home/bin/fm-backend.sh" <<'SH'
fm_backend_source() { return 0; }
fm_backend_of_meta() { sed -n 's/^backend=//p' "$1"; }
fm_meta_get() { sed -n "s/^$2=//p" "$1" | head -n 1; }
fm_backend_herdr_cli() {
  local pane=
  while [ "$#" -gt 0 ]; do [ "$1" != --pane ] || { shift; pane=$1; }; shift || true; done
  case "$pane" in match) model=claude-sonnet-5-5 ;; mismatch|failing|parked-worker) model= ;; *) return 2 ;; esac
  if [ -n "$model" ]; then
    printf '{"result":{"process_info":{"foreground_processes":[{"name":"claude","argv":["claude","--resume","abc","--model","%s"]}]}}}\n' "$model"
  else
    printf '{"result":{"process_info":{"foreground_processes":[{"name":"claude","argv":["claude","--resume","abc"]}]}}}\n'
  fi
}
SH
cat >"$d/home/bin/fm-gate-refuse-lib.sh" <<'SH'
fm_refuse_if_gate_agent() { return 0; }
SH
cat >"$d/home/bin/fm-wake-lib.sh" <<'SH'
fm_lock_try_acquire() { return 0; }
fm_lock_release() { :; }
SH
: >"$d/home/bin/fm-supervision-lib.sh"
: >"$d/home/bin/fm-operational-input.sh"
: >"$d/home/bin/fm-classify-lib.sh"
for cmd in fm-control.sh fm-secondmate-restart.sh; do
  cat >"$d/home/bin/$cmd" <<'SH'
#!/usr/bin/env bash
printf '%s %s %s\n' "$FM_HOME" "$(basename "$0")" "$*" >> "$RELAUNCH_LOG"
[ "${1:-}" != bad ]
SH
  chmod +x "$d/home/bin/$cmd"
done
for row in 'match:match' 'mismatch:mismatch' 'unmodeled:mismatch'; do
  IFS=: read -r id pane <<<"$row"
  cat >"$d/home/state/$id.meta" <<EOF
harness=claude
model=claude-sonnet-5-5
kind=scout
backend=herdr
herdr_session=default
herdr_pane_id=$pane
EOF
  [ "$id" != unmodeled ] || sed -i '/^model=/d' "$d/home/state/$id.meta"
done
: > "$d/relaunch.log"
OUT=$(PATH="$PATH" RELAUNCH_LOG="$d/relaunch.log" FM_HOME="$d/home" FM_SENTINEL_MODEL_EVENT=fixture-event \
  "$ROOT/sentinel/bin/fm-sentinel.sh" model-reconcile 2>&1) || :
printf '%s\n' "$OUT" | grep -q '^unmodeled: stored model missing; model restore refused$'
[ "$(wc -l < "$d/relaunch.log")" -eq 1 ]
rm "$d/home/state/unmodeled.meta"
grep -q "$d/home fm-control.sh mismatch relaunch --model claude-sonnet-5-5" "$d/relaunch.log"
PATH="$PATH" RELAUNCH_LOG="$d/relaunch.log" FM_HOME="$d/home" FM_SENTINEL_MODEL_EVENT=fixture-event \
  "$ROOT/sentinel/bin/fm-sentinel.sh" model-reconcile
[ "$(wc -l < "$d/relaunch.log")" -eq 1 ]
printf 'PASS: main-home mismatch relaunches once per event\n'

for home in lead-a lead-b parked; do
  mkdir -p "$d/$home/state"
  cp -a "$d/home/bin" "$d/$home/"
done
for row in 'lead-a:bad:failing' 'lead-b:good:mismatch' 'parked:parked-worker:mismatch'; do
  IFS=: read -r home id pane <<<"$row"
  cat >"$d/$home/state/$id.meta" <<EOF
harness=claude
model=claude-sonnet-5-5
kind=scout
backend=herdr
herdr_session=default
herdr_pane_id=$pane
EOF
done
printf -- '- lead-a - Lead (home: %s; scope: work)\n- lead-b - Lead (home: %s; scope: work)\n- parked - Lead (home: %s; scope: work)\n- missing - Lead (home: %s; scope: work)\n' \
  "$d/lead-a" "$d/lead-b" "$d/parked" "$d/missing" >"$d/home/data-secondmates.md"
mkdir -p "$d/home/data" "$d/home/config"
mv "$d/home/data-secondmates.md" "$d/home/data/secondmates.md"
printf 'parked\n' >"$d/home/config/parked-homes"
if PATH="$PATH" RELAUNCH_LOG="$d/relaunch.log" FM_HOME="$d/home" FM_SENTINEL_MODEL_EVENT=lead-event \
  "$ROOT/sentinel/bin/fm-sentinel.sh" lead-model-reconcile; then
  echo 'expected failing lead relaunch to report failure' >&2; exit 1
fi
grep -q "$d/lead-b fm-control.sh good relaunch --model claude-sonnet-5-5" "$d/relaunch.log"
[ "$(grep -c "$d/lead-b fm-control.sh good" "$d/relaunch.log")" -eq 1 ]
[ "$(grep -c "$d/lead-a fm-control.sh bad" "$d/relaunch.log")" -eq 1 ]
if grep -q "$d/parked fm-control.sh" "$d/relaunch.log"; then exit 1; fi
if grep -q "$d/missing fm-control.sh" "$d/relaunch.log"; then exit 1; fi
[ "$(wc -l < "$d/relaunch.log")" -eq 3 ]
PATH="$PATH" RELAUNCH_LOG="$d/relaunch.log" FM_HOME="$d/home" FM_SENTINEL_MODEL_EVENT=lead-event \
  "$ROOT/sentinel/bin/fm-sentinel.sh" lead-model-reconcile
[ "$(wc -l < "$d/relaunch.log")" -eq 3 ]
printf 'PASS: lead homes use their own FM_HOME; failures continue; markers deduplicate\n'
