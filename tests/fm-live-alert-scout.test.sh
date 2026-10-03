#!/usr/bin/env bash
# Behavior tests for bin/fm-live-alert-scout.sh.
#
# Drives the public interface (one note id in, one dispatched scout out) over a
# fake code root and a fake home. The home holds a real inbox written by
# fm-inbox.sh, a real markdown backlog served by tasks-axi, and briefs scaffolded
# by the real fm-brief.sh. Only the two tools that spend money or start an
# agent, fm-spawn.sh and fm-dispatch-resolve.sh, are stubs that record their
# argv, so no case starts a worker or reaches a network.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if ! command -v tasks-axi >/dev/null 2>&1; then
  echo "skip: tasks-axi not found; live alert scout cases not run"
  exit 0
fi

TMP_ROOT=$(fm_test_tmproot fm-live-alert-scout)
unset TASKS_AXI_FILE TASKS_AXI_BACKEND FM_HOME FM_ROOT_OVERRIDE \
  FM_DATA_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE

CODE="$TMP_ROOT/code"
HOME_DIR="$TMP_ROOT/home"
SPAWN_LOG="$TMP_ROOT/spawn.log"
NOTE_AT=2026-10-03T16:53:20Z
ALERT_TEXT='[Lloegrys live] Alerta: 1 assinatura(s) nova(s) de warning/error/fatal no log do jogo (luascript); detalhe só no host, em docker logs lloegrys-game.'

mkdir -p "$CODE/docs"
cp -R "$ROOT/bin" "$CODE/bin"
cp -R "$ROOT/docs/templates" "$CODE/docs/templates"
cp "$ROOT/.tasks.toml" "$CODE/.tasks.toml"

cat >"$CODE/bin/fm-spawn.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$SPAWN_LOG"
SH
cat >"$CODE/bin/fm-dispatch-resolve.sh" <<'SH'
#!/usr/bin/env bash
case "${FAKE_RESOLVE_STATUS:-clear}" in
  clear) printf 'dispatch-resolve:\n  status: clear\n  profile: --harness claude --model opus --effort high\n' ;;
  *) printf 'dispatch-resolve:\n  status: %s\n' "$FAKE_RESOLVE_STATUS" ;;
esac
SH
chmod +x "$CODE/bin/fm-spawn.sh" "$CODE/bin/fm-dispatch-resolve.sh"

mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$HOME_DIR/projects/lloegrys-live"
printf '## In flight\n\n## Queued\n\n## Done\n' >"$HOME_DIR/data/backlog.md"
: >"$SPAWN_LOG"

run_scout() {
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$CODE" "$CODE/bin/fm-live-alert-scout.sh" "$@"
}

queue_note() {  # <text>; prints the note id
  local out id
  out=$(FM_HOME="$HOME_DIR" "$CODE/bin/fm-inbox.sh" note -- "$1") || fail "could not queue note"
  id=$(printf '%s\n' "$out" | sed -n 's/^queued //p')
  sed "s/^at=.*/at=$NOTE_AT/" "$HOME_DIR/state/inbox/$id.note" >"$TMP_ROOT/note.tmp"
  cat "$TMP_ROOT/note.tmp" >"$HOME_DIR/state/inbox/$id.note"
  printf '%s\n' "$id"
}

test_valid_alert_dispatches_scout() {
  local id item out rc=0 brief
  id=$(queue_note "$ALERT_TEXT")
  item="lloegrys-live-alerta-$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')"
  out=$(run_scout "$id" 2>&1) || rc=$?
  expect_code 0 "$rc" "a valid alert note must dispatch"
  assert_equals "$item window=2026-10-03T16:43:20Z/2026-10-03T16:58:20Z profile=--harness claude --model opus --effort high" \
    "$out" "the single output line names the item, the window and the profile"
  assert_grep "- [ ] $item - " "$HOME_DIR/data/backlog.md" "the item must be queued in the backlog"
  assert_grep "(repo: lloegrys-live) (kind: scout) (priority: 0)" "$HOME_DIR/data/backlog.md" \
    "the item must be a priority 0 scout for lloegrys-live"
  brief=$(cat "$HOME_DIR/data/$item/brief.md")
  assert_not_contains "$brief" "{TASK}" "the intent placeholder must be filled"
  assert_not_contains "$brief" "{FIRSTMATE_SPEC}" "the spec placeholder must be filled"
  assert_not_contains "$brief" "{WINDOW_SINCE}" "template placeholders must all be filled"
  assert_contains "$brief" "$ALERT_TEXT" "the brief must carry the alert text"
  assert_contains "$brief" "ssh lloegrys-linux 'sudo -n docker logs --since 2026-10-03T16:43:20Z --until 2026-10-03T16:58:20Z lloegrys-game 2>&1'" \
    "the brief must carry the read-only log command for the window"
  assert_contains "$brief" "SOMENTE LEITURA" "the brief must forbid writing to the host"
  bash -c '
    . "$1/bin/fm-dod-lib.sh"
    ! fm_brief_task_placeholders_present "$2" || exit 1
    fm_brief_task_content_valid "$2" || exit 2
    ! fm_brief_intent_address_line "$2" >/dev/null || exit 3
  ' _ "$CODE" "$HOME_DIR/data/$item/brief.md" \
    || fail "the brief must pass the placeholder, content and address checks fm-spawn.sh applies (code $?)"
  assert_equals "$item $HOME_DIR/projects/lloegrys-live --scout --harness claude --model opus --effort high" \
    "$(cat "$SPAWN_LOG")" "the scout must be spawned once for the project with the resolved profile"
  assert_present "$HOME_DIR/state/inbox/$id.note" "the note must stay pending"
  assert_absent "$HOME_DIR/state/inbox/handled/$id.note" "the script must not mark the note handled"
  pass "a valid alert note becomes one queued P0 scout, dispatched, with the note left pending"
  LAST_ID=$id
  LAST_ITEM=$item
}

test_repeat_is_idempotent() {
  local out rc=0 before
  before=$(grep -c "$LAST_ITEM" "$HOME_DIR/data/backlog.md")
  out=$(run_scout "$LAST_ID" 2>&1) || rc=$?
  expect_code 0 "$rc" "a repeat must exit 0"
  assert_equals "$LAST_ITEM already exists: state=queued" "$out" "a repeat prints the item state"
  assert_equals "$before" "$(grep -c "$LAST_ITEM" "$HOME_DIR/data/backlog.md")" "a repeat must not add a second item"
  assert_equals 1 "$(wc -l <"$SPAWN_LOG" | tr -d ' ')" "a repeat must not spawn again"
  pass "a repeated note id prints the state and creates nothing"
}

test_non_alert_note_is_refused() {
  local id out rc=0 lines_before
  lines_before=$(wc -l <"$HOME_DIR/data/backlog.md")
  id=$(queue_note "lembrar de revisar o PR do cliente")
  out=$(run_scout "$id" 2>&1) || rc=$?
  expect_code 1 "$rc" "a note that is not a live alert must be refused"
  assert_contains "$out" "is not a live alert" "the refusal must say why"
  assert_equals "$lines_before" "$(wc -l <"$HOME_DIR/data/backlog.md")" "a refused note must not touch the backlog"
  assert_absent "$HOME_DIR/data/lloegrys-live-alerta-$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')" \
    "a refused note must not scaffold a brief"
  assert_equals 1 "$(wc -l <"$SPAWN_LOG" | tr -d ' ')" "a refused note must not spawn"
  pass "a note that does not start with the alert prefix is refused with no side effect"
}

test_unknown_note_is_refused() {
  local out rc=0
  out=$(run_scout nao-existe 2>&1) || rc=$?
  expect_code 1 "$rc" "an unknown note id must be refused"
  assert_contains "$out" "no inbox note nao-existe" "the refusal must name the id"
  pass "an unknown note id is refused"
}

test_unresolved_profile_uses_static_harness() {
  local id item out rc=0
  id=$(queue_note "$ALERT_TEXT")
  item="lloegrys-live-alerta-$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')"
  out=$(FAKE_RESOLVE_STATUS=ambiguous run_scout "$id" 2>&1) || rc=$?
  expect_code 0 "$rc" "an ambiguous profile must still dispatch"
  assert_contains "$out" "profile=static" "the output must say the static harness was used"
  assert_equals "$item $HOME_DIR/projects/lloegrys-live --scout" "$(tail -n 1 "$SPAWN_LOG")" \
    "the spawn must carry no profile flags"
  pass "a non-clear profile dispatches on the static harness"
}

test_escalate_leaves_item_undispatched() {
  local id item out rc=0 spawns
  spawns=$(wc -l <"$SPAWN_LOG")
  id=$(queue_note "$ALERT_TEXT")
  item="lloegrys-live-alerta-$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')"
  out=$(FAKE_RESOLVE_STATUS=escalate run_scout "$id" 2>&1) || rc=$?
  expect_code 3 "$rc" "an escalate status must stop undispatched"
  assert_contains "$out" "needs the captain's approval" "the message must name the blocker"
  assert_contains "$out" "fm-spawn.sh $item" "the message must give the spawn command to run after the decision"
  assert_equals "$spawns" "$(wc -l <"$SPAWN_LOG")" "an escalate status must not spawn"
  assert_grep "$item" "$HOME_DIR/data/backlog.md" "the item must stay queued"
  pass "an escalate status leaves the item queued and names the follow-up command"
}

test_valid_alert_dispatches_scout
test_repeat_is_idempotent
test_non_alert_note_is_refused
test_unknown_note_is_refused
test_unresolved_profile_uses_static_harness
test_escalate_leaves_item_undispatched
