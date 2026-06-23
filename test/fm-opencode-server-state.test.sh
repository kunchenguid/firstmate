#!/usr/bin/env bash
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-opencode-server.XXXXXX")
ID=opencode-server-test-$$
META="$ROOT/state/$ID.meta"

cleanup() {
  PATH="$TMP/bin:$PATH" FM_OPENCODE_SERVER_MOCK=1 "$ROOT/bin/fm-teardown.sh" "$ID" --force >/dev/null 2>&1 || true
  rm -rf "$TMP" "$ROOT/data/$ID"
  rm -f "$META" "$ROOT/state/$ID.status" "$ROOT/state/$ID.turn-ended" "$ROOT/state/$ID.opencode-server.log"
}
trap cleanup EXIT

mkdir -p "$TMP/bin" "$ROOT/data/$ID" "$ROOT/state"
cat > "$TMP/bin/opencode" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo "opencode 0-test" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/opencode"
printf '@echo off\r\nif "%%1"=="--version" echo opencode 0-test\r\nexit /b 0\r\n' > "$TMP/bin/opencode.cmd"

git init --bare "$TMP/origin.git" >/dev/null
git init "$TMP/project" >/dev/null
git -C "$TMP/project" config user.email firstmate-test@example.com
git -C "$TMP/project" config user.name Firstmate
git -C "$TMP/project" config core.autocrlf false
git -C "$TMP/project" config core.eol lf
git -C "$TMP/project" config core.filemode false
printf 'project\n' > "$TMP/project/README.md"
git -C "$TMP/project" add README.md
git -C "$TMP/project" commit -m init >/dev/null
git -C "$TMP/project" branch -M main
git -C "$TMP/project" remote add origin "$TMP/origin.git"
git -C "$TMP/project" push -u origin main >/dev/null 2>&1

printf 'brief\n' > "$ROOT/data/$ID/brief.md"
OUT=$(PATH="$TMP/bin:$PATH" FM_BACKEND=opencode-server FM_OPENCODE_SERVER_MOCK=1 "$ROOT/bin/fm-spawn.sh" "$ID" "$TMP/project" opencode)
printf '%s\n' "$OUT" | grep -q '^spawned '
printf '%s\n' "$OUT" | grep -q 'backend=opencode-server'
printf '%s\n' "$OUT" | grep -q 'session=mock-'

grep -qx 'backend=opencode-server' "$META"
grep -qx "window=fm-$ID" "$META"
grep -qx 'harness=opencode' "$META"
grep -qx 'kind=ship' "$META"
grep -qx 'mode=no-mistakes' "$META"
grep -qx 'yolo=off' "$META"
grep -qx 'opencode_server_url=http://127.0.0.1:0' "$META"
grep -qx 'opencode_server_pid=0' "$META"
grep -qx "opencode_session_id=mock-$ID" "$META"
grep -qx "opencode_session_title=fm-$ID" "$META"
grep -qx 'opencode_session_state=active' "$META"

WT=$(grep '^worktree=' "$META" | cut -d= -f2-)
case "$WT" in
  "$ROOT/state/opencode-server-worktrees/$ID") ;;
  *) echo "unexpected worktree path: $WT" >&2; exit 1 ;;
esac
[ -d "$WT" ]
git -C "$WT" rev-parse --is-inside-work-tree >/dev/null

CAPTURE=$(FM_ROOT="$ROOT" FM_OPENCODE_SERVER_MOCK=1 bash -c '. "$1/bin/fm-backend.sh"; fm_backend_capture "$2" 5' bash "$ROOT" "$META")
printf '%s\n' "$CAPTURE" | grep -q 'opencode-server status: idle'
STATUS=$(FM_ROOT="$ROOT" FM_OPENCODE_SERVER_MOCK=1 bash -c '. "$1/bin/fm-backend.sh"; fm_backend_status "$2"' bash "$ROOT" "$META")
[ "$STATUS" = status=idle ]
FM_ROOT="$ROOT" FM_OPENCODE_SERVER_MOCK=1 bash -c '. "$1/bin/fm-backend.sh"; fm_backend_send_text "$2" "hello"' bash "$ROOT" "$META"
FM_ROOT="$ROOT" FM_OPENCODE_SERVER_MOCK=1 bash -c '. "$1/bin/fm-backend.sh"; fm_backend_send_key "$2" Escape' bash "$ROOT" "$META"

if ! PATH="$TMP/bin:$PATH" FM_OPENCODE_SERVER_MOCK=1 "$ROOT/bin/fm-teardown.sh" "$ID" >"$TMP/teardown.out" 2>"$TMP/teardown.err"; then
  git -C "$WT" status --porcelain >&2 || true
  cat "$TMP/teardown.err" >&2
  exit 1
fi
[ ! -e "$META" ]
[ ! -d "$WT" ]
