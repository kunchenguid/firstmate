#!/usr/bin/env bash
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-backend-regression.XXXXXX")
ID=codex-app-test-$$
cleanup() {
  rm -rf "$TMP" "$ROOT/data/$ID" "$ROOT/state/$ID.meta" "$ROOT/state/$ID.turn-ended" "$ROOT/state/$ID.codex-app.capture"
}
trap cleanup EXIT

backend_name() {
  FM_ROOT="$TMP" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_name' bash "$ROOT"
}

[ "$(backend_name)" = tmux ]
mkdir -p "$TMP/config"
printf 'orca\n' > "$TMP/config/backend"
[ "$(backend_name)" = orca ]
printf 'FM_BACKEND="codex-app"\n' > "$TMP/config/backend.env"
[ "$(backend_name)" = orca ]
FM_BACKEND=codex-app FM_ROOT="$TMP" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_name' bash "$ROOT" | grep -qx codex-app
printf 'opencode-server\n' > "$TMP/config/backend"
[ "$(backend_name)" = opencode-server ]

mkdir -p "$ROOT/data/$ID" "$ROOT/state" "$TMP/project"
printf 'brief\n' > "$ROOT/data/$ID/brief.md"
OUT=$(FM_BACKEND=codex-app "$ROOT/bin/fm-spawn.sh" "$ID" "$TMP/project" codex)
printf '%s\n' "$OUT" | grep -q '^prepared '
printf '%s\n' "$OUT" | grep -q 'create_thread or fork_thread'
META="$ROOT/state/$ID.meta"
grep -qx 'backend=codex-app' "$META"
grep -qx 'window=fm-'"$ID" "$META"
grep -qx 'codex_app_thread_state=pending' "$META"
grep -qx 'codex_app_pending_action=create_thread_or_fork_thread' "$META"
! grep -q '^thread_id=' "$META"
! grep -q '^codex_app_runner_pid=' "$META"
! grep -q '^codex_app_state=' "$META"
printf 'thread_id=thread-enter\n' >> "$META"
if FM_ROOT="$ROOT" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_send_key "$2" Enter' bash "$ROOT" "$META" 2>"$TMP/enter.err"; then
  echo "expected Codex App Enter key send to fail through host-tool refusal" >&2
  exit 1
fi
grep -q 'send_message_to_thread' "$TMP/enter.err"

meta_line=$(grep -n '> "$FM_ROOT/state/$ID.meta"' "$ROOT/bin/fm-spawn.sh" | cut -d: -f1)
orca_launch_line=$(grep -n 'orca terminal send --terminal "$ORCA_TERMINAL" --text "$LAUNCH"' "$ROOT/bin/fm-spawn.sh" | cut -d: -f1)
[ "$meta_line" -lt "$orca_launch_line" ]

grep -q 'FM_ORCA_CODEX_AUTO_TRUST' "$ROOT/bin/fm-spawn.sh"
if grep -q 'codex\\*) fm_backend_trust_codex_project "$WT"' "$ROOT/bin/fm-spawn.sh"; then
  echo "Orca+Codex trust must be explicit opt-in" >&2
  exit 1
fi
