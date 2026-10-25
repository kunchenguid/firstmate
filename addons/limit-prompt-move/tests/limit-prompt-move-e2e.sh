#!/usr/bin/env bash
# limit-prompt-move e2e: the real pass on a fixture home whose panes show weekly-limit-menu.screen,
# a real Claude Code 2.1.310 capture (path and time zone scrubbed). A lead with no account moves to
# the pool's pick, a worker with --account next, each by fm-control interrupt then relaunch only; a
# pane only quoting the menu, a Codex pane and a second pass move nothing; a failed relaunch blocks.
set -u
# Usage: limit-prompt-move-e2e.sh [--installed]

here=$(cd "$(dirname "$0")" && pwd) || exit 1
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
home=$work/home
S=$home/state
mkdir -p "$S" "$home/config" "$home/bin" "$home/state"
fails=0
is() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "not ok - $1: got [$2], want [$3]"; fails=$((fails + 1)); fi; }

cat >"$home/bin/fm-backend.sh" <<'EOF'
fm_meta_get() { [ -f "$1" ] || return 0; sed -n "s|^$2=||p" "$1" | tail -n 1; }
fm_backend_of_meta() { echo fixture; }; fm_backend_target_of_meta() { fm_meta_get "$1" endpoint_task_id; }
fm_backend_visible_capture() { cat "$FM_HOME/state/$2.screen" 2>/dev/null; return 0; }
EOF
# No fm-account-pool-lib.sh in the home's bin/, as since firstmate PR 128: the pass loads the account-pool
# add-on's lib. The pool tool is a stub that answers a fixed pick; no real login or account is touched.
printf 'fm_run_timed() { shift; "$@"; }\n' >"$home/bin/fm-timeout-lib.sh"
mkdir -p "$work/pool/pa_most_room"
cat >"$work/byokit-accounts" <<'EOF2'
#!/usr/bin/env bash
printf '{"ok":true,"id":"pa_most_room","set":{"CLAUDE_CONFIG_DIR":"%s"},"unset":[]}\n' "$(dirname "$0")/pool/pa_most_room"
EOF2
chmod +x "$work/byokit-accounts"
printf 'state=%s\ncommand=%s\n' "$work/pool" "$work/byokit-accounts" >"$home/config/account-pool"
# fm-control stub: records each call; a relaunch records the new account and generation and clears the screen.
cat >"$home/bin/fm-control.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FM_HOME/state/control.log"
[ "$2" = relaunch ] || exit 0
[ ! -f "$FM_HOME/state/$1.relaunch-fails" ] || { echo "error: the pool cannot start a claude worker"; exit 1; }
acct=$4; [ "$acct" = next ] && acct=pa_next
printf 'account=%s\nspawn_gen=s2\n' "$acct" >>"$FM_HOME/state/$1.meta"
rm -f "$FM_HOME/state/$1.screen"
EOF
chmod +x "$home/bin/fm-control.sh"

pass=$here/../limit-prompt-move
if [ "${1:-}" = --installed ]; then # the copy install.sh ships, run from its own folder
  printf '#!/bin/sh\n' >"$home/bin/fm-check-register.sh"; chmod +x "$home/bin/fm-check-register.sh"
  XDG_DATA_HOME=$work/share "$here/../install.sh" "$home" >/dev/null || exit 1
  pass=$work/share/fm-limit-prompt-move/limit-prompt-move/limit-prompt-move
fi

task() { # <id> <kind> <harness> [account]
  printf 'endpoint_task_id=%s\nkind=%s\nharness=%s\nspawn_gen=s1\naccount=%s\n' "$1" "$2" "$3" "${4:-}" >"$S/$1.meta"
  cp "$here/weekly-limit-menu.screen" "$S/$1.screen"
}
task muxr-lead secondmate claude
task notes-worker ship claude pa_full
task codex-worker ship codex pa_codex
task quoting-worker ship claude pa_quote
printf '❯ \n  ? for shortcuts\n' >>"$S/quoting-worker.screen"

FM_HOME=$home "$pass" "$home"
is "only the two panes on the menu are moved, interrupt first, never another verb" "$(sed 's/ --note-file .*//' "$S/control.log")" \
"muxr-lead interrupt
muxr-lead relaunch --account pa_most_room
notes-worker interrupt
notes-worker relaunch --account next"
is "the lead's status logs its move to the pool's pick" "$(sed 's/\[at=[0-9]*\]/[at=N]/' "$S/muxr-lead.status")" \
  "working [at=N]: limit-prompt-move: sat on Claude's usage-limit menu; moved off its unrecorded account to account pa_most_room"
is "the worker's status logs its move off the full account" "$(sed 's/\[at=[0-9]*\]/[at=N]/' "$S/notes-worker.status")" \
  "working [at=N]: limit-prompt-move: sat on Claude's usage-limit menu; moved off account pa_full to account pa_next"
is "a Codex pane and a pane that only quotes the menu get no status line" "$(ls "$S"/codex-worker.status "$S"/quoting-worker.status 2>/dev/null)" ""
is "each move is one log line" "$(grep -c 'moved off' "$S/limit-prompt-move.log")" 2

: >"$S/control.log"
cp "$here/weekly-limit-menu.screen" "$S/notes-worker.screen"
sed -i 's/^spawn_gen=s2$/spawn_gen=s1/' "$S/notes-worker.meta"
FM_HOME=$home "$pass" "$home"
is "one attempt per incarnation: a second pass on the same generation moves nothing" "$(cat "$S/control.log")" ""

task stuck-worker ship claude pa_full
touch "$S/stuck-worker.relaunch-fails"
FM_HOME=$home "$pass" "$home"
is "a failed relaunch leaves a blocked status line naming fm-control's error" "$(sed 's/\[at=[0-9]*\]/[at=N]/' "$S/stuck-worker.status")" \
  "blocked [key=limit-prompt-move] [at=N]: limit-prompt-move: sat on Claude's usage-limit menu; interrupted, but relaunch --account next failed: error: the pool cannot start a claude worker"

[ "$fails" -eq 0 ] && echo "PASS limit-prompt-move" || { echo "FAIL limit-prompt-move ($fails)"; exit 1; }
