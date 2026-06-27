#!/usr/bin/env bash
# fm-layout.sh — arrange the firstmate orchestrator window into a captain
# dashboard: a left command column (top 2/3 orchestrator chat, bottom 1/3 a terse
# active-worker summary) taking 1/3 width, and a right 2/3 column split into three
# stacked worker watch slots. The watch slots are READ-ONLY mirrors of live worker
# windows (capture-pane loops, bin/fm-watch-pane.sh); workers keep running in their
# own windows untouched, so nothing here ever moves, kills, or obscures real work.
#
# Safe to re-run: arrange rebuilds only its own viewer panes (those tagged
# @fm_role=slot:* / summary), never the orchestrator pane, never a worker, and
# never panes it does not recognize (it refuses a window holding unexpected panes
# unless --force). Slot assignments survive a rebuild when their worker is still
# live. The orchestrator pane stays the focused, fully usable command pane.
#
# Worker discovery is delegated to bin/fm-layout-lib.sh, so "which workers exist"
# is identical across the summary pane, the watch panes, and the picker.
#
# Subcommands:
#   arrange [--window <id>] [--force]   build/refresh the dashboard (default)
#   workers                             print live workers as idx<TAB>window<TAB>repo<TAB>label
#   slots                               print the three slot assignments
#   assign <1|2|3> <window|->            assign a worker to a slot (- clears it)
#   pick [1|2|3]                        open the interactive picker popup
#   mouse-pick -p <pane> -c <client>    right-click handler (resolves slot from pane)
#   bind [--mouse]                      install opt-in runtime keybindings
#   unbind                              remove them
#
# Keybindings are runtime-only (tmux bind-key / set, never ~/.tmux.conf) and
# opt-in via `bind`. See docs/orchestrator-layout.md for the picker UX, the
# right-click caveats, and how to undo everything.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
export FM_LAYOUT_STATE="$STATE"
BIN="$SCRIPT_DIR"

# shellcheck source=bin/fm-layout-lib.sh
. "$SCRIPT_DIR/fm-layout-lib.sh"

# Opt-in prefix keys (capitals, not default tmux bindings); overridable so a
# captain whose config already uses them can pick others.
KEY_ARRANGE="${FM_LAYOUT_KEY_ARRANGE:-O}"
KEY_PICK="${FM_LAYOUT_KEY_PICK:-P}"

die() { echo "fm-layout: $*" >&2; exit 1; }

require_tmux() {
  command -v tmux >/dev/null 2>&1 || die "tmux not found; this is a tmux layout tool"
  [ -n "${TMUX:-}" ] || [ -n "${FM_LAYOUT_ALLOW_NO_TMUX:-}" ] \
    || die "not inside a tmux session; run this from your firstmate terminal"
}

# ---- worker / slot helpers -------------------------------------------------

# Print live workers with a 1-based index for the picker and tests.
cmd_workers() {
  local i=0 line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    i=$((i + 1))
    printf '%d\t%s\n' "$i" "$line"
  done <<EOF
$(fm_layout_workers)
EOF
}

# Echo the TSV record (window\trepo\tlabel) of a live worker by its window, or
# empty if it is not a live worker.
worker_record() {  # <window>
  local want=$1 line win
  while IFS= read -r line; do
    win=${line%%	*}
    [ "$win" = "$want" ] && { printf '%s' "$line"; return 0; }
  done <<EOF
$(fm_layout_workers)
EOF
  return 0
}

cmd_assign() {  # <slot> <window|->
  [ $# -eq 2 ] || die "usage: fm-layout.sh assign <1|2|3> <window|->"
  local slot=$1 target=$2 file rec
  case "$slot" in 1|2|3) ;; *) die "slot must be 1, 2, or 3" ;; esac
  file=$(fm_layout_slot_file "$STATE" "$slot")
  if [ "$target" = "-" ] || [ -z "$target" ]; then
    rm -f "$file"
    echo "slot $slot cleared"
    return 0
  fi
  rec=$(worker_record "$target")
  [ -n "$rec" ] || die "'$target' is not a live worker (see: fm-layout.sh workers)"
  printf '%s\n' "$rec" > "$file"
  echo "slot $slot -> $target"
}

cmd_slots() {
  local slot file line
  for slot in 1 2 3; do
    file=$(fm_layout_slot_file "$STATE" "$slot")
    if [ -f "$file" ]; then line=$(cat "$file"); else line=""; fi
    printf '%s\t%s\n' "$slot" "$line"
  done
}

# Fill slot files: keep existing assignments whose worker is still live, then
# fill empty slots from live workers not already shown. Never spawns work; an
# empty slot just stays empty when there are fewer than three live workers.
autofill_slots() {
  local workers slot file win assigned=" " line
  workers=$(fm_layout_workers)
  # Drop stale assignments (worker window no longer live) and collect kept ones.
  for slot in 1 2 3; do
    file=$(fm_layout_slot_file "$STATE" "$slot")
    [ -f "$file" ] || continue
    win=$(head -1 "$file" | cut -f1)
    if printf '%s\n' "$workers" | cut -f1 | grep -Fxq "$win"; then
      assigned="$assigned$win "
    else
      rm -f "$file"
    fi
  done
  # Fill empties from unassigned live workers, in discovery order.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    win=${line%%	*}
    case "$assigned" in *" $win "*) continue ;; esac
    for slot in 1 2 3; do
      file=$(fm_layout_slot_file "$STATE" "$slot")
      [ -f "$file" ] && continue
      printf '%s\n' "$line" > "$file"
      assigned="$assigned$win "
      break
    done
  done <<EOF
$workers
EOF
}

# ---- arrange ---------------------------------------------------------------

viewer_cmd() {  # <slot|summary> -> shell command string for split-window
  printf 'FM_LAYOUT_STATE=%q exec %q %q' "$STATE" "$BIN/fm-watch-pane.sh" "$1"
}

cmd_arrange() {
  require_tmux
  local win="" force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --window) win=$2; shift 2 ;;
      --force) force=1; shift ;;
      *) die "arrange: unknown arg '$1'" ;;
    esac
  done
  [ -n "$win" ] || win=$(tmux display-message -p '#{window_id}') \
    || die "could not resolve the current tmux window"

  # Refuse to restructure a worker window (named fm-*); only the orchestrator
  # window is ours to arrange.
  local wname
  wname=$(tmux display-message -p -t "$win" '#{window_name}' 2>/dev/null) \
    || die "window '$win' not found"
  case "$wname" in
    fm-*) [ "$force" -eq 1 ] || die "'$wname' looks like a worker window; refusing to arrange it (pass --force to override)" ;;
  esac

  # Identify the orchestrator pane: a previously-tagged one, else the active pane.
  local orch
  orch=$(tmux list-panes -t "$win" -F '#{pane_id} #{@fm_role}' \
    | awk '$2=="orchestrator"{print $1; exit}')
  [ -n "$orch" ] || orch=$(tmux display-message -p -t "$win" '#{pane_id}')

  # Tear down only our own prior viewer panes; never the orchestrator or anything
  # we do not recognize.
  local pid role
  while read -r pid role; do
    [ "$pid" = "$orch" ] && continue
    case "$role" in
      slot:*|summary) tmux kill-pane -t "$pid" 2>/dev/null || true ;;
    esac
  done < <(tmux list-panes -t "$win" -F '#{pane_id} #{@fm_role}')

  # After clearing our viewers, only the orchestrator should remain. Unknown
  # leftover panes are not destroyed without an explicit --force.
  local remaining
  remaining=$(tmux list-panes -t "$win" -F '#{pane_id}' | grep -c .)
  if [ "$remaining" -ne 1 ]; then
    if [ "$force" -eq 1 ]; then
      tmux list-panes -t "$win" -F '#{pane_id}' | while read -r pid; do
        [ "$pid" = "$orch" ] || tmux kill-pane -t "$pid" 2>/dev/null || true
      done
    else
      die "window has $((remaining - 1)) unexpected pane(s) besides the command pane; close them or pass --force"
    fi
  fi

  # Pre-populate slot assignments so the first paint shows workers immediately.
  autofill_slots

  local height third slot1 slot2 slot3 summary
  height=$(tmux display-message -p -t "$win" '#{window_height}')
  case "$height" in ''|*[!0-9]*) height=24 ;; esac
  third=$((height / 3))
  [ "$third" -ge 1 ] || third=1

  # Right 2/3 column, three stacked watch slots.
  slot1=$(tmux split-window -h -t "$orch" -l 66% -d -P -F '#{pane_id}' "$(viewer_cmd 1)")
  slot2=$(tmux split-window -v -t "$slot1" -d -P -F '#{pane_id}' "$(viewer_cmd 2)")
  slot3=$(tmux split-window -v -t "$slot2" -d -P -F '#{pane_id}' "$(viewer_cmd 3)")
  tmux resize-pane -t "$slot1" -y "$third" 2>/dev/null || true
  tmux resize-pane -t "$slot2" -y "$third" 2>/dev/null || true

  # Left column: orchestrator keeps the top 2/3, summary takes the bottom 1/3.
  summary=$(tmux split-window -v -t "$orch" -l 33% -d -P -F '#{pane_id}' "$(viewer_cmd summary)")

  # Tag roles so re-runs and the mouse picker can find panes; titles for clarity.
  tmux set -p -t "$orch" @fm_role orchestrator
  tmux set -p -t "$slot1" @fm_role slot:1
  tmux set -p -t "$slot2" @fm_role slot:2
  tmux set -p -t "$slot3" @fm_role slot:3
  tmux set -p -t "$summary" @fm_role summary
  tmux set -w -t "$win" @fm_layout 1
  tmux select-pane -t "$orch" -T 'orchestrator' 2>/dev/null || true
  tmux select-pane -t "$slot1" -T 'watch 1' 2>/dev/null || true
  tmux select-pane -t "$slot2" -T 'watch 2' 2>/dev/null || true
  tmux select-pane -t "$slot3" -T 'watch 3' 2>/dev/null || true
  tmux select-pane -t "$summary" -T 'workers' 2>/dev/null || true
  tmux set -w -t "$win" pane-border-status top 2>/dev/null || true

  # Keep the captain in the command pane.
  tmux select-pane -t "$orch"
  echo "dashboard arranged in $wname: command column (orchestrator + worker summary), 3 watch slots"
}

# ---- picker entrypoints ----------------------------------------------------

cmd_pick() {  # [slot]
  require_tmux
  local slot=${1:-}
  tmux display-popup -E "$BIN/fm-layout-pick.sh${slot:+ $slot}"
}

cmd_mouse_pick() {  # -p <pane> -c <client>
  local pane="" client=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -p) pane=$2; shift 2 ;;
      -c) client=$2; shift 2 ;;
      *) shift ;;
    esac
  done
  [ -n "$pane" ] || exit 0
  local role slot
  role=$(tmux show -p -t "$pane" -v @fm_role 2>/dev/null || true)
  case "$role" in
    slot:*) slot=${role#slot:} ;;
    *) exit 0 ;;  # right-click outside a watch pane: harmless no-op
  esac
  if [ -n "$client" ]; then
    tmux display-popup -c "$client" -E "$BIN/fm-layout-pick.sh $slot"
  else
    tmux display-popup -E "$BIN/fm-layout-pick.sh $slot"
  fi
}

# ---- keybindings (opt-in, runtime-only) ------------------------------------

cmd_bind() {
  require_tmux
  local mouse=0
  [ "${1:-}" = "--mouse" ] && mouse=1
  tmux bind-key "$KEY_ARRANGE" run-shell "$BIN/fm-layout.sh arrange --window '#{window_id}'"
  tmux bind-key "$KEY_PICK" display-popup -E "$BIN/fm-layout-pick.sh"
  echo "bound: prefix+$KEY_ARRANGE = arrange/refresh, prefix+$KEY_PICK = pick worker"
  if [ "$mouse" -eq 1 ]; then
    tmux set -g mouse on
    tmux bind-key -n MouseDown3Pane \
      run-shell "$BIN/fm-layout.sh mouse-pick -p '#{mouse_pane}' -c '#{client_name}'"
    echo "mouse: right-click a watch pane to reassign it"
    echo "note: this enabled tmux mouse mode and rebound right-click SERVER-WIDE (best-effort)."
    echo "      undo with: fm-layout.sh unbind  (then: tmux set -g mouse off  if you want mouse off)"
  fi
}

cmd_unbind() {
  require_tmux
  tmux unbind-key "$KEY_ARRANGE" 2>/dev/null || true
  tmux unbind-key "$KEY_PICK" 2>/dev/null || true
  tmux unbind-key -n MouseDown3Pane 2>/dev/null || true
  echo "unbound prefix+$KEY_ARRANGE, prefix+$KEY_PICK, and right-click."
  echo "mouse mode left unchanged; run 'tmux set -g mouse off' to disable it if you enabled it here."
}

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
}

# ---- dispatch --------------------------------------------------------------

cmd=${1:-arrange}
[ $# -gt 0 ] && shift || true
case "$cmd" in
  arrange) cmd_arrange "$@" ;;
  workers) cmd_workers ;;
  slots) cmd_slots ;;
  assign) cmd_assign "$@" ;;
  pick) cmd_pick "$@" ;;
  mouse-pick) cmd_mouse_pick "$@" ;;
  bind) cmd_bind "$@" ;;
  unbind) cmd_unbind ;;
  -h|--help|help) usage ;;
  *) die "unknown subcommand '$cmd' (try: arrange, workers, slots, assign, pick, bind, unbind)" ;;
esac
