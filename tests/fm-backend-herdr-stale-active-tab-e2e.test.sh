#!/usr/bin/env bash
# Real-Herdr regression for the teardown active-tab guard: persisted
# .focused is not a live viewer. A pane on that tab must close when no
# foreground client is attached.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo 'skip: herdr not found'; exit 0; }
command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found'; exit 0; }
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-stale-active-tab-e2e.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-herdr-teardown-stale-active-tab-guard-r1)
export HERDR_LAB_HELPER HERDR_LAB_SESSION HERDR_ORIGINAL_PATH
cleanup() {
  local status=$?
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  rm -rf "$TMP_ROOT"
  exit "$status"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
last=$((${#args[@]} - 1))
flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] \
  && [ "${args[$flag]}" = --session ] \
  && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in --session|--session=*) exit 9 ;; esac
done
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"

lab() { env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }

CREATE=$(lab workspace create --cwd "$ROOT" --label 'stale-active-tab' --no-focus) \
  || fail 'could not create the persisted-focus workspace'
PANE=$(printf '%s' "$CREATE" | jq -er '.result.root_pane.pane_id') \
  || fail 'could not read the created pane id'
TAB=$(printf '%s' "$CREATE" | jq -er '.result.tab.tab_id') \
  || fail 'could not read the created tab id'
lab tab focus "$TAB" >/dev/null || fail 'could not persist focus onto the target tab'

TITLE=$(lab terminal title clear) \
  || fail 'could not probe foreground-client attachment'
REASON=$(printf '%s' "$TITLE" | jq -er '.result.reason') \
  || fail "could not parse the title-clear reason: $TITLE"
[ "$REASON" = no_foreground_client ] \
  || fail "lab unexpectedly had a foreground client (reason=$REASON)"

FOCUSED=$(lab workspace list | jq -er '[.result.workspaces[] | select(.focused == true)] | select(length == 1) | .[0].active_tab_id') \
  || fail 'could not read the persisted focused tab'
[ "$FOCUSED" = "$TAB" ] || fail "persisted focus was $FOCUSED, not the target tab $TAB"

OUT=$(PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" bash -c '
  . "$1/bin/backends/herdr.sh"
  fm_backend_herdr_cli() {
    local session=$1
    shift
    HERDR_SESSION="$session" herdr "$@" --session "$session"
  }
  fm_backend_herdr_projection_close_pane_focus_preserving "$2" "$3"
' _ "$ROOT" "$HERDR_LAB_SESSION" "$PANE" 2>&1)
STATUS=$?
[ "$STATUS" -eq 0 ] || fail "detached persisted-focus close failed (status $STATUS): $OUT"
case "$OUT" in
  *"target is the captain's active tab"*)
    fail "detached persisted-focus close still used the live-viewer refusal: $OUT"
    ;;
esac
if lab pane get "$PANE" >/dev/null 2>&1; then
  fail 'detached persisted-focus close left the pane behind'
fi
pass 'detached client: persisted .focused on the target tab does not block pane close'
