#!/usr/bin/env bash
# Real projected spawn guard: only a named Herdr lab session is ever touched.
# A disposable clone stands in for the already leased copy, so the guard never
# allocates, returns, or changes the developer's shared Treehouse pool.
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/fixtures.sh
. "$ROOT/tests/fixtures.sh"
fm_live_gate default-on FM_HERDR_PROJECTED_CD_LIVE_E2E herdr jq
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-herdr-projected-cd-fix)
export HERDR_LAB_HELPER HERDR_LAB_SESSION
ORIGINAL_PATH=$PATH
export ORIGINAL_PATH

TMP_ROOT=$(mktemp -d /tmp/fm-projected-cd.XXXXXX)
cleanup() {
  local status=$?
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  find "$TMP_ROOT" -type d -exec chmod u+rwx {} +
  rm -rf "$TMP_ROOT"
  exit "$status"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
mkdir -p "$TMP_ROOT/fakebin"
cat > "$TMP_ROOT/fakebin/herdr" <<'EOF'
#!/usr/bin/env bash
set -eu
args=("$@")
if [ "${1:-}" = --version ]; then
  PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" status --json | jq -r '"herdr " + .client.version'
  exit
fi
n=${#args[@]}
[ "$n" -lt 2 ] || {
  [ "${args[n-2]}" != --session ] || {
    [ "${args[n-1]}" = "$HERDR_LAB_SESSION" ] || exit 1
    unset 'args[n-1]' 'args[n-2]'
  }
}
if [ "${args[0]:-} ${args[1]:-}" = 'pane run' ] && [[ "${args[3]:-}" == 'cd -- '* ]]; then
  printf 'cd\n' >> "${TEST_SLOT}.entry-sends"
  if [ "$DELAY_ENTRY" = 1 ] && [ ! -e "${TEST_SLOT}.entry-delayed" ]; then
    : > "${TEST_SLOT}.entry-delayed"
    args[3]="sleep 15; ${args[3]}"
  fi
fi
exec env PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "${args[@]}"
EOF
cat > "$TMP_ROOT/fakebin/treehouse" <<'EOF'
#!/usr/bin/env bash
case "$1" in
get) printf '%s\n' "$TEST_SLOT" ;;
*) echo 'test refuses pool administration' >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP_ROOT/fakebin/"*
lab() { "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
VERSION=$(lab status --json | jq -er '.client.version')
# Projection is a default only at or above the presentation floor, so ask the
# same classifier fm-spawn consults; a supported release below it spawns flat.
FLOOR=$(PATH="$TMP_ROOT/fakebin:$PATH" bash -c '
  . "$1/bin/backends/herdr.sh"
  status=0
  fm_backend_herdr_presentation_release_supported "$2" || status=$?
  printf "%s %s %s\n" "$status" "$FM_BACKEND_HERDR_MIN_PRESENTATION_VERSION" "$FM_BACKEND_HERDR_PRESENTATION_RELEASE"
' _ "$ROOT" "$HERDR_LAB_SESSION")
FLOOR_STATUS=${FLOOR%% *}
FLOOR=${FLOOR#* }
FLOOR_VERSION=${FLOOR%% *}
FLOOR_RELEASE=${FLOOR#* }
case "$FLOOR_STATUS" in
  0) ;;
  1)
    printf 'skip: Herdr %s is below the %s presentation floor, so spawns stay flat\n' \
      "$FLOOR_RELEASE" "$FLOOR_VERSION"
    exit 0
    ;;
  *) fail "Herdr $FLOOR_RELEASE could not be classified against the presentation floor" ;;
esac
HERDR_SOCKET_PATH=$(lab session list --json | jq -er --arg session "$HERDR_LAB_SESSION" '.sessions[] | select(.name == $session) | .socket_path')
export HERDR_SOCKET_PATH
fm_git_init_commit "$TMP_ROOT/project"
PARENT=$(lab workspace create --cwd "$TMP_ROOT/project" --label firstmate --focus)
HERDR_PANE_ID=$(printf '%s' "$PARENT" | jq -er '.result.root_pane.pane_id')
export HERDR_PANE_ID
for DELAY_ENTRY in 0 1; do
  export DELAY_ENTRY
  CASE="$TMP_ROOT/case-$DELAY_ENTRY"
  mkdir -p "$CASE"
  git clone -q "$TMP_ROOT/project" "$CASE/slot"
  export TEST_SLOT="$CASE/slot"
  fm_test_spawn_home "$CASE/home" codex
  fm_test_spawn_brief "$CASE/home" projected-cd 'Exercise a projected shell worktree entry.'
  if ! PATH="$TMP_ROOT/fakebin:$PATH" FM_HOME="$CASE/home" FM_ROOT_OVERRIDE="$ROOT" FM_SPAWN_NO_GUARD=1 HERDR_SESSION="$HERDR_LAB_SESSION" \
    bash "$ROOT/bin/fm-spawn.sh" projected-cd "$TMP_ROOT/project" "sh -c 'while :; do sleep 60; done'" --backend herdr --mode no-mistakes --yolo off > "$CASE/spawn.log" 2>&1; then
    cat "$CASE/spawn.log" >&2
    fail "Herdr $VERSION projected spawn failed (delayed=$DELAY_ENTRY)"
  fi
  [ -s "$CASE/home/state/projected-cd.herdr-presentation" ] \
    || fail "Herdr $VERSION guard fell back to a flat spawn"
  PANE=$(sed -n 's/^herdr_pane_id=//p' "$CASE/home/state/projected-cd.meta")
  [ -n "$PANE" ] || fail "Herdr $VERSION spawn recorded no pane"
  ACTUAL=$(lab pane get "$PANE" | jq -er '.result.pane.foreground_cwd')
  EXPECTED=$(cd "$TEST_SLOT" && pwd -P)
  [ "$ACTUAL" = "$EXPECTED" ] || fail "Herdr $VERSION pane cwd $ACTUAL != $EXPECTED"
  [ "$DELAY_ENTRY" = 0 ] || [ -e "${TEST_SLOT}.entry-delayed" ] \
    || fail "Herdr $VERSION delayed entry was not exercised"
  SENDS=$(wc -l < "${TEST_SLOT}.entry-sends" | tr -d '[:space:]')
  [ "$SENDS" = "$((DELAY_ENTRY + 1))" ] \
    || fail "Herdr $VERSION expected $((DELAY_ENTRY + 1)) cd sends, observed $SENDS"
  pass "Herdr $VERSION projected spawn enters its recorded copy (delayed=$DELAY_ENTRY)"
done
