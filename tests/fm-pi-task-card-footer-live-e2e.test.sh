#!/usr/bin/env bash
# Opt-in real Pi/Herdr visual evidence for the task-card footer at three widths.
# The fixture contributes eight unreadable live tasks so page one visibly has
# more than six cards while each unreadable state is rendered as Unknown.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_PI_TASK_CARD_FOOTER_LIVE_E2E pi herdr jq

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name live-task-card-footer)
LIVE_HOME=$(mktemp -d "${TMPDIR:-/tmp}/fm-task-card-footer-live.XXXXXX")
trap '"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"; rm -rf "$LIVE_HOME"' EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" >/dev/null

mkdir -p "$LIVE_HOME/state" "$LIVE_HOME/data" "$LIVE_HOME/config" "$LIVE_HOME/projects"
for i in 01 02 03 04 05 06 07 08; do
  printf 'kind=ship\nworktree=%s/absent-%s\nbackend=tmux\n' "$LIVE_HOME" "$i" > "$LIVE_HOME/state/footer-$i.meta"
done

wide_workspace=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" workspace create --cwd "$ROOT" --label footer-wide --no-focus)
wide_pane=$(printf '%s' "$wide_workspace" | jq -r '.result.root_pane.pane_id')
[ -n "$wide_pane" ] && [ "$wide_pane" != null ] || fail "Herdr did not return the wide pane id"
wide_layout=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane layout --pane "$wide_pane")
wide_width=$(printf '%s' "$wide_layout" | jq -r --arg pane "$wide_pane" '.result.layout.panes[] | select(.pane_id == $pane) | .rect.width')
[ "$wide_width" -ge 110 ] && [ "$wide_width" -le 130 ] || fail "Herdr wide pane is not 110-130 columns"

grid_workspace=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" workspace create --cwd "$ROOT" --label footer-grid --no-focus)
grid_pane=$(printf '%s' "$grid_workspace" | jq -r '.result.root_pane.pane_id')
[ -n "$grid_pane" ] && [ "$grid_pane" != null ] || fail "Herdr did not return the grid pane id"
grid_split=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane split "$grid_pane" --direction right --ratio 0.66 --no-focus)
narrow_pane=$(printf '%s' "$grid_split" | jq -r '.. | objects | .pane_id? // empty' | tail -n 1)
[ -n "$narrow_pane" ] && [ "$narrow_pane" != null ] || fail "Herdr did not return the narrow pane id"

start_pi() {
  local target=$1
  "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane run "$target" env \
    FM_HOME="$LIVE_HOME" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$LIVE_HOME/state" FM_DATA_OVERRIDE="$LIVE_HOME/data" \
    pi --no-session --no-context-files --no-extensions \
      -e "$ROOT/.pi/extensions/fm-task-card-footer.ts" \
      --model openai-codex/gpt-5.6-sol --thinking low >/dev/null
  "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane wait-output \
    "$target" --source visible --match 'Attention 8' --timeout 20000 >/dev/null
}

visible() {
  "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane read "$1" --source visible --lines 100 --format text
}

start_pi "$wide_pane"
wide=$(visible "$wide_pane")
printf '%s\n' "$wide" | grep -Eq 'T01.*T02.*T03' \
  || fail "wide Herdr Pi footer did not render three cards across"
printf '%s\n' "$wide" | grep -Fq 'T06' \
  || fail "wide Herdr Pi footer did not show six cards on page one"

layout=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane layout --pane "$grid_pane")
medium_width=$(printf '%s' "$layout" | jq -r --arg pane "$grid_pane" '.result.layout.panes[] | select(.pane_id == $pane) | .rect.width')
narrow_width=$(printf '%s' "$layout" | jq -r --arg pane "$narrow_pane" '.result.layout.panes[] | select(.pane_id == $pane) | .rect.width')
[ "$medium_width" -ge 70 ] && [ "$medium_width" -le 90 ] || fail "Herdr medium pane is not 70-90 columns"
[ "$narrow_width" -ge 30 ] && [ "$narrow_width" -le 50 ] || fail "Herdr narrow pane is not 30-50 columns"

# Headless Herdr currently reports the full virtual terminal width to child Pi
# processes even when pane geometry is narrower. The pane layout above is the
# live width evidence; the deterministic renderer test owns exact 2/1-column
# assertions for those widths.
start_pi "$grid_pane"
medium=$(visible "$grid_pane")
printf '%s\n' "$medium" | grep -Fq 'T06' \
  || fail "medium Herdr Pi footer did not show six cards on page one"

start_pi "$narrow_pane"
narrow_text=$(visible "$narrow_pane")
printf '%s\n' "$narrow_text" | grep -Fq 'T01' \
  || fail "narrow Herdr Pi footer did not render a card"

pass "real Pi $(pi --version) under Herdr exercised eight task cards across wide, medium, and narrow pane geometry"
