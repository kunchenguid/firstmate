#!/usr/bin/env bash
# Drive the real firstmate scripts (fm-inactive-reconcile, fm-wake-grant,
# fm-wake-drain, fm-crew-state) against a disposable lab FM_HOME: a done child
# with a held PR, presented once to an away-posture branch, then N cadence scans.
# Usage: away-held-pr-cadence.sh <bin-dir> <label>
set -u
BIN=$1 LABEL=$2 CYCLES=${CYCLES:-6}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"
"$BIN/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/tmux"
export FM_HOME="$LAB" TMUX_TMPDIR="$LAB/tmux"
unset TMUX FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE FM_PROJECTS_OVERRIDE NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS
old=$(( $(date +%s) - 600 )); stamp=$(date -r "$old" +%Y%m%d%H%M.%S)
id=treehouse-apfs-clone-s1
p="$LAB/projects/$id"; mkdir -p "$p"
git -C "$p" init -q; git -C "$p" -c user.name=lab -c user.email=lab@example.invalid commit -q --allow-empty -m init
sha=$(git -C "$p" rev-parse HEAD); git -C "$p" update-ref refs/remotes/origin/main "$sha"
printf '%s\n' "window=firstmate:fm-$id" "worktree=$p" "project=$p" harness=claude kind=ship mode=no-mistakes yolo=off \
  spawn_gen=s1.lab pr=https://github.com/kunchenguid/treehouse/pull/153 "pr_head=$sha" > "$LAB/state/$id.meta"
echo "done: PR https://github.com/kunchenguid/treehouse/pull/153 open/green/mergeable, held for captain return" > "$LAB/state/$id.status"
: > "$LAB/state/$id.turn-ended"
touch -t "$stamp" "$LAB/state/$id.meta" "$LAB/state/$id.status" "$LAB/state/$id.turn-ended"
q() { awk -F '\t' '$4 ~ /^inactive-outcome:/' "$LAB/state/.wake-queue" 2>/dev/null | wc -l | tr -d ' '; }
rec() { find "$LAB/state" -path "*inactive-outcome*" -name "*.$1" 2>/dev/null | wc -l | tr -d ' '; }
scan() { FM_INACTIVE_RECONCILE_SECS=60 "$BIN/fm-inactive-reconcile.sh" scan "$@"; }
tmux -L fm-lab new-session -d -s firstmate -n "fm-$id" -c "$p" 'exec sh' || exit 1
sock=$(tmux -L fm-lab display-message -p '#{socket_path}'); spid=$(tmux -L fm-lab display-message -p '#{pid}')
export TMUX="$sock,$spid,0"
sleep 1
# The child's Claude Stop hook: arm the incarnation, then post the idle turn end.
gen=$("$BIN/fm-busy-event.sh" arm "$LAB/state" "$id") && "$BIN/fm-busy-event.sh" apply "$LAB/state" "$id" idle --gen "$gen" --source claude-hook --event Stop || echo "busy arm failed"
touch -t "$stamp" "$LAB/state/$id".* 2>/dev/null
echo "== [$LABEL] lab FM_HOME=$LAB (child pane firstmate:fm-$id on private fm-lab tmux socket)"
echo "crew-state: $("$BIN/fm-crew-state.sh" "$id" 2>&1 | head -1)"
scan --startup
echo "startup scan: queued inactive-outcome rows=$(q) pending receipts=$(rec pending)"
seq=$(awk -F '\t' '$4 ~ /^inactive-outcome:/ {print $2}' "$LAB/state/.wake-queue" | tail -1)
"$BIN/fm-wake-grant.sh" activate "$$" away-branch && "$BIN/fm-wake-grant.sh" publish away-branch "$seq" || echo "grant failed"
presented=0
for cycle in $(seq 1 "$CYCLES"); do
  err=$(mktemp)
  out=$(FM_SUPERVISION_ACTOR=branch "$BIN/fm-wake-drain.sh" 2>"$err")
  if printf '%s' "$out" | grep -q 'inactive terminal outcome'; then
    presented=$((presented+1))
    echo "cycle $cycle: branch drain PRESENTED -> $(printf '%s' "$out" | grep -o 'inactive terminal outcome[^\\n]*' | head -1)"
    a=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9]*\) --recovery-generation \(.*\)$/\1 \2/p' "$err")
    FM_SUPERVISION_ACTOR=branch "$BIN/fm-wake-drain.sh" --ack-through ${a%% *} --recovery-generation ${a#* } || echo "ack failed"
  else
    echo "cycle $cycle: branch drain presented nothing"
  fi
  rm -f "$err"
  touch -t "$stamp" "$LAB/state/.inactive-outcome-reconcile" 2>/dev/null
  scan
  seq=$(awk -F '\t' '$4 ~ /^inactive-outcome:/ {print $2}' "$LAB/state/.wake-queue" | tail -1)
  echo "  after cadence scan $cycle: queued=$(q) pending=$(rec pending) presented-receipts=$(rec presented)"
  [ -z "$seq" ] || "$BIN/fm-wake-grant.sh" publish away-branch "$seq" >/dev/null 2>&1
done
echo "== [$LABEL] RESULT: unchanged held PR presented $presented time(s) across $CYCLES away cadences"
if [ "${CHANGE:-}" = 1 ]; then
  echo "-- situation changes: the child reports a new PR (PR #154) and its turn ends again"
  sed -i '' 's#pull/153#pull/154#' "$LAB/state/$id.meta"
  echo "done: PR https://github.com/kunchenguid/treehouse/pull/154 open/green/mergeable, held for captain return" >> "$LAB/state/$id.status"
  touch -t "$stamp" "$LAB/state/$id".* "$LAB/state/.inactive-outcome-reconcile"
  scan
  seq=$(awk -F '\t' '$4 ~ /^inactive-outcome:/ {print $2}' "$LAB/state/.wake-queue" | tail -1)
  "$BIN/fm-wake-grant.sh" publish away-branch "$seq" >/dev/null 2>&1
  out=$(FM_SUPERVISION_ACTOR=branch "$BIN/fm-wake-drain.sh" 2>/dev/null)
  echo "after change: queued=$(q); branch drain presents: $(printf '%s' "$out" | grep -o 'child=[^ ]* state=[a-z]* pr=[^ ]*' | head -1)"
fi
tmux -L fm-lab kill-server 2>/dev/null
rm -rf "$LAB"
