#!/usr/bin/env bash
# Drive the real firstmate scripts in a disposable marked lab home:
# away record -> inactive-outcome scan -> branch grant/drain/captain report/ack
# -> repeated cadence scans; count re-queued rows and captain reports.
# Usage: lab-flood-repro.sh <firstmate-root>
set -u
R=$1
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"
"$R/bin/fm-lab-home.sh" create "$LAB" >/dev/null
export FM_HOME="$LAB"
S=$LAB/state
proj=$LAB/projects/held; mkdir -p "$proj"
git -C "$proj" init -q; git -C "$proj" -c user.name=t -c user.email=t@e.invalid commit -q --allow-empty -m init
sha=$(git -C "$proj" rev-parse HEAD); git -C "$proj" update-ref refs/remotes/origin/main "$sha"
cat > "$S/held.meta" <<EOF
window=fm-held
worktree=$proj
project=$proj
harness=claude
kind=ship
mode=no-mistakes
yolo=off
spawn_gen=g1
pr=https://github.com/kunchenguid/treehouse/pull/153
pr_head=$sha
EOF
echo 'done: PR https://github.com/kunchenguid/treehouse/pull/153 open/green/mergeable' > "$S/held.status"
: > "$S/held.turn-ended"
old=$(( $(date +%s) - 600 )); perl -e '$t=shift; utime $t,$t,@ARGV' "$old" "$S/held.meta" "$S/held.status" "$S/held.turn-ended"
echo "## crew state (real fm-crew-state.sh): $("$R/bin/fm-crew-state.sh" held 2>&1 | head -1)"
"$R/bin/fm-afk-contract.sh" enter --words "watch the fleet; merge nothing" >/dev/null && echo "## away record entered"
export FM_INACTIVE_RECONCILE_SECS=60
# The only substitute: the pane read. A real done crew needs a live harness
# pane (or an attributed no-mistakes run); this lab has neither, so crew-state
# answers "done" as the away window's finished crew did.
mkdir -p "$LAB/fakebin"
printf '#!/usr/bin/env bash\nprintf "state: done · source: fake\\n"\n' > "$LAB/fakebin/fm-crew-state.sh"
chmod +x "$LAB/fakebin/fm-crew-state.sh"
export FM_INACTIVE_CREW_STATE_BIN="$LAB/fakebin/fm-crew-state.sh"
q() { grep -c $'\tinactive-outcome:' "$S/.wake-queue" 2>/dev/null; true; }
PRES=0; captains() { echo "$PRES"; }
branch_turn() {  # one away branch turn: grant queued rows, branch drain, branch ack
  local seqs seq out err ack gen
  seqs=$(awk -F '\t' '$2 ~ /^[0-9]+$/ {print $2}' "$S/.wake-queue" 2>/dev/null | tr '\n' ' ')
  [ -n "$seqs" ] || return 0
  "$R/bin/fm-wake-grant.sh" activate "$$" lab-branch >/dev/null
  "$R/bin/fm-wake-grant.sh" publish lab-branch $seqs >/dev/null
  out=$(FM_SUPERVISION_ACTOR=branch "$R/bin/fm-wake-drain.sh" 2>"$LAB/err")
  case "$out" in *inactive-outcome:*) PRES=$((PRES+1)) ;; esac
  echo "   drain presented: $(printf '%s' "$out" | grep -v '^WAKE_' | tr '\n' ' ' | cut -c1-160)"
  ack=$(sed -n 's/.*--ack-through \([0-9]*\) --recovery-generation.*/\1/p' "$LAB/err")
  gen=$(sed -n 's/.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$LAB/err")
  FM_SUPERVISION_ACTOR=branch "$R/bin/fm-wake-drain.sh" --ack-through "$ack" --recovery-generation "$gen" >/dev/null 2>&1 || echo "   ack failed"
  "$R/bin/fm-wake-grant.sh" release lab-branch >/dev/null 2>&1 || true
}
for n in 1 2 3 4 5 6; do
  [ -e "$S/.inactive-outcome-reconcile" ] && perl -e '$t=time-120; utime $t,$t,@ARGV' "$S/.inactive-outcome-reconcile"
  "$R/bin/fm-inactive-reconcile.sh" scan 2>/dev/null
  echo "## cadence $n: queued inactive-outcome rows=$(q); pending receipts=$(ls "$S"/terminal-outcomes/*.pending 2>/dev/null | wc -l | tr -d ' ')"
  branch_turn
  echo "   after branch turn: queued=$(q) branch presentations of the held outcome so far=$(captains)"
done
echo "## new event: decision appended to the held task's status"
echo 'needs-decision [key=merge-153]: merge PR 153 now or hold it for the return?' >> "$S/held.status"
bash -c '. "$1/bin/fm-wake-lib.sh"; fm_wake_append signal held.status "$2"' _ "$R" "held: needs-decision [key=merge-153]: merge PR 153 now or hold it for the return?"
echo "   queue after decision: $(awk -F '\t' '{print $3" "$4}' "$S/.wake-queue" 2>/dev/null | tr '\n' ';')"
branch_turn
echo "## FINAL branch presentations of the held outcome=$(captains)"
rm -rf "$LAB"
