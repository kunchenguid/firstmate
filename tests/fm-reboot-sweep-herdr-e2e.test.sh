#!/usr/bin/env bash
# Real-Herdr E2E for boot recovery authority detection and primary nudge dedupe.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-reboot-herdr-e2e.XXXXXX")
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name FM-BUG-006) || {
  rm -rf "$TMP_ROOT"
  fail "could not generate the isolated Herdr lab session"
}
CLEANED=0
cleanup() {
  local status=0
  [ "$CLEANED" -eq 0 ] || return 0
  CLEANED=1
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=$?
  rm -rf "$TMP_ROOT"
  return "$status"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
  || fail "could not provision the isolated Herdr lab session"

lab() {
  "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
}

FIXTURE_HOME="$TMP_ROOT/firstmate-home"
SECOND_HOME="$TMP_ROOT/secondmate-home"
FIXTURE_STATE="$FIXTURE_HOME/state"
FAKEBIN="$TMP_ROOT/fakebin"
FAKE_LOG="$TMP_ROOT/fake.log"
BOOT_ID_FILE="$TMP_ROOT/boot-id"
mkdir -p "$FIXTURE_STATE" "$SECOND_HOME" "$FAKEBIN"
: > "$FAKE_LOG"
printf '%s\n' 'fm-bug-006-herdr-boot' > "$BOOT_ID_FILE"

primary_json=$(lab workspace create --cwd "$FIXTURE_HOME" --label fm-bug-006-primary --no-focus) \
  || fail "could not create the fake primary workspace"
PRIMARY_PANE=$(printf '%s' "$primary_json" | jq -r '.result.root_pane.pane_id')
[ -n "$PRIMARY_PANE" ] || fail "fake primary pane id is empty"
lab pane send-text "$PRIMARY_PANE" 'stty -echo; cat' >/dev/null \
  || fail "could not prepare the fake primary input sink"
lab pane send-keys "$PRIMARY_PANE" enter >/dev/null \
  || fail "could not start the fake primary input sink"
lab pane report-agent "$PRIMARY_PANE" --source fm-bug-006 --agent claude --state idle >/dev/null \
  || fail "could not register the fake primary agent"

second_json=$(lab workspace create --cwd "$SECOND_HOME" --label fm-bug-006-secondmate --no-focus) \
  || fail "could not create the fake secondmate workspace"
SECOND_PANE=$(printf '%s' "$second_json" | jq -r '.result.root_pane.pane_id')
[ -n "$SECOND_PANE" ] || fail "fake secondmate pane id is empty"
lab pane send-text "$SECOND_PANE" "printf '%s\\n' 'accept edits on'" >/dev/null \
  || fail "could not write the broken authority fixture"
lab pane send-keys "$SECOND_PANE" enter >/dev/null \
  || fail "could not submit the broken authority fixture"
lab pane report-agent "$SECOND_PANE" --source fm-bug-006 --agent claude --state idle >/dev/null \
  || fail "could not register the fake secondmate agent"
sleep 0.5

cat > "$FIXTURE_STATE/lab-mate.meta" <<META
kind=secondmate
harness=claude
backend=herdr
window=$HERDR_LAB_SESSION:$SECOND_PANE
META

cat > "$FAKEBIN/systemctl" <<'SH'
#!/usr/bin/env bash
set -eu
printf 'systemctl' >> "$FM_REBOOT_E2E_LOG"
printf ' <%s>' "$@" >> "$FM_REBOOT_E2E_LOG"
printf '\n' >> "$FM_REBOOT_E2E_LOG"
case " $* " in
  *" is-failed "*) exit 1 ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/systemctl"

cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$FAKEBIN/tmux"

cat > "$FAKEBIN/bizmate-start" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'bizmate-start' >> "$FM_REBOOT_E2E_LOG"
SH
chmod +x "$FAKEBIN/bizmate-start"

run_recovery() {
  PATH="$FAKEBIN:$PATH" \
    FM_HOME="$FIXTURE_HOME" \
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_REBOOT_BOOT_ID_FILE="$BOOT_ID_FILE" \
    FM_REBOOT_HERDR_LAB_HELPER="$HERDR_LAB_HELPER" \
    FM_REBOOT_HERDR_SESSION="$HERDR_LAB_SESSION" \
    FM_REBOOT_BIZMATE_START="$FAKEBIN/bizmate-start" \
    FM_REBOOT_SYSTEMCTL="$FAKEBIN/systemctl" \
    FM_REBOOT_TMUX="$FAKEBIN/tmux" \
    FM_REBOOT_WATCHER_CONFIRM=0 \
    FM_REBOOT_E2E_LOG="$FAKE_LOG" \
    "$ROOT/bin/fm-reboot-sweep.sh" --recover
}

first=$(run_recovery) || fail "first real-pane recovery run failed"
second=$(run_recovery) || fail "repeated real-pane recovery run failed"
case "$first" in *'nudge=sent'*) : ;; *) fail "first real-pane recovery did not send a nudge" ;; esac
case "$second" in *'nudge=deduped'*) : ;; *) fail "repeated real-pane recovery did not dedupe the nudge" ;; esac

primary_capture=$(lab pane read "$PRIMARY_PANE" --source recent --lines 80 --format text) \
  || fail "could not capture the fake primary pane"
nudge_count=$(printf '%s\n' "$primary_capture" | grep -o 'FIRSTMATE_OP:' | wc -l | tr -d ' ')
[ "$nudge_count" = 1 ] \
  || fail "expected exactly one marked primary nudge, got $nudge_count"$'\n'"$primary_capture"
primary_flat=$(printf '%s' "$primary_capture" | tr -d '\r\n')
case "$primary_flat" in
  *"lab-mate($HERDR_LAB_SESSION:$SECOND_PANE=accept-edits)"*) : ;;
  *) fail "the marked primary nudge omitted the broken authority and explicit target"$'\n'"$primary_capture" ;;
esac

scan=$(PATH="$FAKEBIN:$PATH" \
  FM_HOME="$FIXTURE_HOME" \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_REBOOT_HERDR_LAB_HELPER="$HERDR_LAB_HELPER" \
  FM_REBOOT_HERDR_SESSION="$HERDR_LAB_SESSION" \
  FM_REBOOT_BIZMATE_START="$FAKEBIN/bizmate-start" \
  FM_REBOOT_TMUX="$FAKEBIN/tmux" \
  FM_REBOOT_E2E_LOG="$FAKE_LOG" \
  "$ROOT/bin/fm-reboot-sweep.sh") || fail "broken-authority real-pane scan failed"
case "$scan" in *'authority=BROKEN mode=accept-edits'*) : ;; *) fail "real pane was not classified as broken"$'\n'"$scan" ;; esac

lab pane send-text "$SECOND_PANE" "printf '%s\\n' 'bypass permissions on'" >/dev/null \
  || fail "could not write the bypass authority fixture"
lab pane send-keys "$SECOND_PANE" enter >/dev/null \
  || fail "could not submit the bypass authority fixture"
sleep 0.5
scan=$(PATH="$FAKEBIN:$PATH" \
  FM_HOME="$FIXTURE_HOME" \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_REBOOT_HERDR_LAB_HELPER="$HERDR_LAB_HELPER" \
  FM_REBOOT_HERDR_SESSION="$HERDR_LAB_SESSION" \
  FM_REBOOT_BIZMATE_START="$FAKEBIN/bizmate-start" \
  FM_REBOOT_TMUX="$FAKEBIN/tmux" \
  FM_REBOOT_E2E_LOG="$FAKE_LOG" \
  "$ROOT/bin/fm-reboot-sweep.sh") || fail "healthy-authority real-pane scan failed"
case "$scan" in *'authority=healthy mode=bypass-permissions'*) : ;; *) fail "real pane was not classified as healthy after bypass appeared last"$'\n'"$scan" ;; esac

case "$(cat "$FAKE_LOG")" in
  *'<start> <--no-block> <fm-boot-watcher.service>'*) : ;;
  *) fail "real-pane recovery did not request the stale watcher backstop" ;;
esac
case "$(cat "$FAKE_LOG")" in
  *'<--secondmate>'*|*'<--channels>'*) fail "timer path attempted a forbidden automatic repair" ;;
esac
pass "real herdr: boot recovery re-arms the stale watcher, classifies authority, and sends one deduped primary nudge"
