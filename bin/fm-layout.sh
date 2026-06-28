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
#   ref -p <pane> [-c <client>]         worker-reference picker: type a worker ref into the composer
#   insert-ref -p <pane> -w <window>    type one worker's reference into a pane
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
# The worker-reference chord. A bare '#' cannot be intercepted inside an agent
# composer (see docs/orchestrator-layout.md), so this is a prefix chord: prefix #.
KEY_REF="${FM_LAYOUT_KEY_REF:-#}"

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

# ---- worker-reference shortcut (the "#"-style picker) ----------------------

# cmd_ref: open a worker picker and type the chosen worker's reference into the
# composer pane. This is the closest practical analog to an "@"/"#" mention: a
# bare '#' cannot be trapped inside a third-party agent composer, so it is reached
# via a prefix chord (prefix #) that captures the active pane, then a tmux
# display-menu (keyboard-navigable AND mouse-clickable, like the @/ pickers).
# Selecting a worker runs `insert-ref`, which send-keys the reference (default the
# short window name) into the composer so the captain never hand-copies a terminal
# target. With --print it prints the menu targets instead (used by tests).
cmd_ref() {  # -p <pane> [-c <client>] [--print]
  require_tmux
  local pane="" client="" printonly=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -p) pane=$2; shift 2 ;;
      -c) client=$2; shift 2 ;;
      --print) printonly=1; shift ;;
      *) shift ;;
    esac
  done
  [ -n "$pane" ] || pane=$(tmux display-message -p '#{pane_id}' 2>/dev/null || true)

  local workers menu=() i=0 win repo label key
  workers=$(fm_layout_workers)
  while IFS=$'\t' read -r win repo label; do
    [ -n "$win" ] || continue
    i=$((i + 1))
    if [ "$printonly" -eq 1 ]; then
      printf '%d\t%s\t%s\n' "$i" "$win" "$(fm_layout_ref "$win")"
      continue
    fi
    if [ "$i" -le 9 ]; then key=$i; else key=""; fi
    menu+=("$repo - $label" "$key" "run-shell \"$BIN/fm-layout.sh insert-ref -p $pane -w $win\"")
  done <<EOF
$workers
EOF

  [ "$printonly" -eq 1 ] && return 0
  if [ "$i" -eq 0 ]; then
    tmux display-message "fm-layout: no active workers to reference"
    return 0
  fi
  [ -n "$client" ] || client=$(tmux display-message -p '#{client_name}' 2>/dev/null || true)
  if [ -n "$client" ]; then
    tmux display-menu -c "$client" -T " #worker -> composer " "${menu[@]}"
  else
    tmux display-menu -T " #worker -> composer " "${menu[@]}"
  fi
}

# cmd_insert_ref: type a worker's reference token into a target pane. Validates the
# window is a live worker first, then send-keys the reference (FM_LAYOUT_REF_FORMAT)
# plus a trailing space so the captain keeps typing the rest of the message.
cmd_insert_ref() {  # -p <pane> -w <window>
  require_tmux
  local pane="" window=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -p) pane=$2; shift 2 ;;
      -w) window=$2; shift 2 ;;
      *) shift ;;
    esac
  done
  [ -n "$pane" ] && [ -n "$window" ] || die "usage: fm-layout.sh insert-ref -p <pane> -w <window>"
  local rec ref
  rec=$(worker_record "$window")
  if [ -z "$rec" ]; then
    tmux display-message "fm-layout: '$window' is no longer a live worker" 2>/dev/null || true
    return 0
  fi
  ref=$(fm_layout_ref "$window")
  tmux send-keys -t "$pane" -l "$ref "
}

# ---- keybindings (opt-in, runtime-only) ------------------------------------

cmd_bind() {
  require_tmux
  local mouse=0
  [ "${1:-}" = "--mouse" ] && mouse=1
  tmux bind-key "$KEY_ARRANGE" run-shell "$BIN/fm-layout.sh arrange --window '#{window_id}'"
  tmux bind-key "$KEY_PICK" display-popup -E "$BIN/fm-layout-pick.sh"
  tmux bind-key "$KEY_REF" run-shell "$BIN/fm-layout.sh ref -p '#{pane_id}' -c '#{client_name}'"
  echo "bound: prefix+$KEY_ARRANGE = arrange/refresh, prefix+$KEY_PICK = pick worker, prefix+$KEY_REF = insert worker reference"
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
  tmux unbind-key "$KEY_REF" 2>/dev/null || true
  tmux unbind-key -n MouseDown3Pane 2>/dev/null || true
  echo "unbound prefix+$KEY_ARRANGE, prefix+$KEY_PICK, prefix+$KEY_REF, and right-click."
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
  ref) cmd_ref "$@" ;;
  insert-ref) cmd_insert_ref "$@" ;;
  bind) cmd_bind "$@" ;;
  unbind) cmd_unbind ;;
  -h|--help|help) usage ;;
  *) die "unknown subcommand '$cmd' (try: arrange, workers, slots, assign, pick, ref, bind, unbind)" ;;
esac
