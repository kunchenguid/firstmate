#!/usr/bin/env bash
# Hermetic executable-interface checks for non-agent prestart cancellation.
# Herdr/ps/backlog are explicit fixtures, not a live-backend or worker proof.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-control-prestart)
mkdir -p "$TMP_ROOT"
trap 'fm_test_cleanup' EXIT
REAL_PS=$(type -P ps)

make_case() {
  D="$TMP_ROOT/$1"
  H="$D/home"
  HOST_HOME="$D/user"
  FB="$D/bin"
  SESSION="fm-lab-prestart-unit-$$-$1"
  SOCKET="$D/socket"
  mkdir -p "$H/state" "$H/data" "$H/config" "$H/projects" "$HOST_HOME" "$FB" "$D/foreign"
  printf 'herdr\n' > "$H/config/backend"
  printf '# Backlog\n' > "$H/data/backlog.md"
  fm_test_tasks_toml "$H/.tasks.toml"
  fm_git_init_commit "$H/projects/app"
  git -C "$H/projects/app" remote add origin https://github.com/fixture/app.git
  cat > "$D/tool" <<'PY'
#!/usr/bin/env python3
import os,sys,json,pathlib,subprocess
D=pathlib.Path(os.environ['PC_DIR']);H=D/'home';P=str(H/'projects/app')
fault=(D/'fault').read_text().strip() if (D/'fault').exists() else ''
stopped=(D/'stopped').exists();name=pathlib.Path(sys.argv[0]).name;a=sys.argv[1:]
def emit(v):print(json.dumps(v));sys.exit(0)
if name=='tasks-axi':
 if a and a[0] in ('--version','version'):print('tasks-axi 0.2.6');sys.exit(0)
 if a and a[0]=='show':
  print('task:\n  id: orphan\n  state: queued\n  held: '+('no' if fault=='not-held' else 'yes')+'\n  kind: scout\n  repo: app');sys.exit(0)
 sys.exit(1)
if name=='ps':
 if '-axo' in a:
  print('90000010 1 bash');sys.exit(0)
 if '-p' in a:
  pid=a[a.index('-p')+1]
  if pid in ('90000011','90000012','90000013'):
   if stopped:sys.exit(1)
   if 'lstart=' in a:print('Thu Jan  1 00:00:01 1970');sys.exit(0)
   if 'ppid=,pgid=,uid=,lstart=' in a:
    parent='90000010' if pid=='90000011' else ('90000012' if pid=='90000013' else ('1' if fault=='bad-parent' else '90000011'))
    stamp='02' if fault=='changed' else '01'
    print(parent+' 90000011 '+str(os.getuid())+' Thu Jan  1 00:00:'+stamp+' 1970');sys.exit(0)
  if pid=='90000010':print('bash');sys.exit(0)
 os.execv(os.environ['PC_REAL_PS'],[os.environ['PC_REAL_PS']]+a)
if name!='herdr':sys.exit(2)
clean=[];i=0
while i<len(a):
 if a[i]=='--session':i+=2;continue
 if a[i]=='--json':i+=1;continue
 clean.append(a[i]);i+=1
a=clean
with (D/'calls').open('a') as f:f.write(' '.join(a)+'\n')
if a==['--version']:print('herdr 0.9.3');sys.exit(0)
if a and a[0]=='status':emit({'server':{'running':fault!='server-gone'}})
if a[:2]==['session','list']:
 emit({'sessions':[{'name':os.environ['HERDR_SESSION'],'running':True,'socket_path':os.environ['HERDR_SOCKET_PATH']}]})
if a[:2]==['workspace','list']:
 emit({'result':{'type':'workspace_list','workspaces':[{'workspace_id':'w1','label':'coordinator','tab_count':2}]}})
if a[:2]==['pane','get']:
 pane=a[2];actor=pane=='w1:p1';cwd=str(H) if actor else P
 if fault=='bad-home' and actor:cwd=str(D/'foreign')
 if fault=='bad-project' and not actor:cwd=str(D/'foreign')
 emit({'result':{'type':'pane','pane':{'pane_id':pane,'workspace_id':'w1','tab_id':'w1:t1' if actor else 'w1:t2','cwd':cwd,'foreground_cwd':cwd}}})
if a[:2]==['tab','get']:
 actor=a[2]=='w1:t1'
 emit({'result':{'type':'tab','tab':{'tab_id':a[2],'workspace_id':'w1','pane_count':1,'label':'coordinator' if actor else 'fm-orphan'}}})
if a[:2]==['tab','list']:
 tabs=[{'tab_id':'w1:t2','workspace_id':'w1','pane_count':1,'label':'fm-orphan'}]
 if fault=='ambiguous':tabs.append({'tab_id':'w1:t3','workspace_id':'w1','pane_count':1,'label':'fm-orphan'})
 emit({'result':{'type':'tab_list','tabs':tabs}})
if a[:2]==['agent','get']:
 if fault=='agent':emit({'result':{'agent':{'agent_status':'working'}}})
 emit({'error':{'code':'agent_not_found'}})
if a[:2]==['pane','process-info']:
 actor=a[a.index('--pane')+1]=='w1:p1'
 if actor:emit({'result':{'type':'pane_process_info','process_info':{'pane_id':'w1:p1','shell_pid':int(os.environ['PC_ACTOR'])}}})
 procs=[] if stopped else [{'pid':90000011,'name':'treehouse','argv':['treehouse','get'],'cwd':P},{'pid':90000012,'name':'git','argv':['git','fetch','origin'],'cwd':P}]
 if not stopped and (D/'remote-command').exists():
  remote=(D/'remote-command').read_text().strip()
  origin=subprocess.check_output(['git','-C',P,'remote','get-url','origin'],text=True).strip()
  name='git' if remote in ('remote-http','remote-https') else remote
  argv=['git',remote] if name=='git' else [remote]
  procs.append({'pid':90000013,'name':name,'argv':argv+['origin',origin],'cwd':P})
 if fault=='unknown-process':procs.append({'pid':90000013,'name':'node','argv':['node','pi'],'cwd':P})
 emit({'result':{'type':'pane_process_info','process_info':{'pane_id':'w1:p2','shell_pid':90000010,'foreground_process_group_id':90000011,'foreground_processes':procs}}})
if a[:2]==['pane','send-keys']:
 with (D/'keys').open('a') as f:f.write(' '.join(a[2:])+'\n')
 if fault!='stuck':(D/'stopped').touch()
 emit({'result':{'type':'ok'}})
print('unexpected fixture command',file=sys.stderr);sys.exit(2)
PY
  chmod +x "$D/tool"
  ln -s "$D/tool" "$FB/herdr"
  ln -s "$D/tool" "$FB/ps"
  ln -s "$D/tool" "$FB/tasks-axi"
}

run_control() {
  FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_DATA_OVERRIDE="$H/data" FM_CONFIG_OVERRIDE="$H/config" \
    HOME="$HOST_HOME" HERDR_SESSION="$SESSION" HERDR_PANE_ID=w1:p1 HERDR_SOCKET_PATH="$SOCKET" \
    FM_HERDR_PS_BIN="$FB/ps" PC_DIR="$D" PC_REAL_PS="$REAL_PS" PC_ACTOR="$$" \
    FM_CONTROL_POLL=0.1 FM_CONTROL_EXIT_WAIT=0.2 PATH="$FB:$PATH" \
    "$ROOT/bin/fm-control.sh" orphan cancel-prestart --pane w1:p2 "$@" 2>&1
}

for remote in none remote-https git-remote-http git-remote-https; do
  make_case "$remote"
  [ "$remote" = none ] || printf '%s\n' "$remote" > "$D/remote-command"
  OUT=$(run_control) || fail "$remote qualifying HTTPS snapshot failed: $OUT"
  PROOF=$(printf '%s' "$OUT" | jq -er .proof) || fail "missing snapshot proof: $OUT"
  [ ! -e "$D/keys" ] || fail "read-only snapshot sent input"
  assert_contains "$OUT" '"input_sent": false' 'snapshot did not say no input was sent'

  git -C "$H/projects/app" remote set-url origin http://github.com/fixture/app.git
  OUT=$(run_control); RC=$?
  [ "$RC" -ne 0 ] || fail "$remote HTTP snapshot was accepted: $OUT"
  OUT=$(run_control --if-match "$PROOF"); RC=$?
  [ "$RC" -ne 0 ] || fail "$remote HTTP cancellation was accepted: $OUT"
  [ ! -e "$D/keys" ] || fail "$remote HTTP rejection sent input"
  [ ! -e "$D/stopped" ] || fail "$remote HTTP rejection stopped the job"
  [ ! -e "$H/state/orphan.meta" ] || fail "$remote HTTP rejection created metadata"
  pass "$remote HTTP snapshot and cancellation refuse without input"

  git -C "$H/projects/app" remote set-url origin https://github.com/fixture/app.git
  OUT=$(run_control --if-match "$PROOF") || fail "$remote verified HTTPS cancellation failed: $OUT"
  assert_contains "$OUT" 'prestart stopped: orphan' 'cancellation did not verify stop'
  [ "$(wc -l < "$D/keys" | tr -d ' ')" = 1 ] || fail "cancellation sent more than one key"
  [ ! -e "$H/state/orphan.meta" ] || fail "cancellation invented task metadata"
  assert_no_grep 'server ' "$D/calls" 'cancellation tried to start a server'
  pass "$remote HTTPS cancels once, verifies stop and never adopts an agent"
done

make_case remote-http
OUT=$(run_control) || fail "initial HTTPS snapshot failed: $OUT"
PROOF=$(printf '%s' "$OUT" | jq -er .proof) || fail 'initial proof missing'
printf 'remote-http\n' > "$D/remote-command"
OUT=$(run_control); RC=$?
[ "$RC" -ne 0 ] || fail "git remote-http with HTTPS origin was accepted: $OUT"
OUT=$(run_control --if-match "$PROOF"); RC=$?
[ "$RC" -ne 0 ] || fail "git remote-http cancellation was accepted: $OUT"
[ ! -e "$D/keys" ] || fail 'git remote-http sent input'
[ ! -e "$D/stopped" ] || fail 'git remote-http stopped the job'
[ ! -e "$H/state/orphan.meta" ] || fail 'git remote-http created metadata'
pass 'git remote-http refuses even with an HTTPS origin'

for fault in bad-home bad-project ambiguous agent unknown-process bad-parent not-held server-gone; do
  make_case "$fault"
  printf '%s\n' "$fault" > "$D/fault"
  OUT=$(run_control); RC=$?
  [ "$RC" -ne 0 ] || fail "$fault was accepted: $OUT"
  [ ! -e "$D/keys" ] || fail "$fault sent input"
  [ ! -e "$H/state/orphan.meta" ] || fail "$fault created metadata"
  pass "$fault refuses without input"
done

make_case producer
(
  export FM_HOME="$H"
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-wake-lib.sh"
  PRODUCER_LOCK=$(fm_treehouse_project_lock_path "$H/projects/app") || fail 'project lock path missing'
  fm_lock_try_acquire "$PRODUCER_LOCK" || fail 'could not model an active native producer'
  trap 'fm_lock_release "$PRODUCER_LOCK"' EXIT
  OUT=$(run_control); RC=$?
  [ "$RC" -ne 0 ] || fail 'a still-active producer was accepted'
  [ ! -e "$D/keys" ] || fail 'an active producer received input'
  [ -e "$PRODUCER_LOCK" ] || fail 'cancellation removed another producer lock'
) || fail 'active producer refusal failed'
pass 'an active native producer stays in control of its project mutex'

make_case changed
OUT=$(run_control) || fail "initial identity snapshot failed: $OUT"
PROOF=$(printf '%s' "$OUT" | jq -er .proof) || fail 'initial proof missing'
printf 'changed\n' > "$D/fault"
OUT=$(run_control --if-match "$PROOF"); RC=$?
[ "$RC" -ne 0 ] || fail 'a stale process identity was accepted'
[ ! -e "$D/keys" ] || fail 'a stale fingerprint sent input'
pass 'changed process start identity invalidates the fingerprint'

make_case record
printf 'backend=herdr\n' > "$H/state/orphan.meta"
OUT=$(run_control); RC=$?
[ "$RC" -ne 0 ] || fail 'an existing task record was bypassed'
[ ! -e "$D/keys" ] || fail 'an existing task record sent input'
pass 'ordinary task records cannot be bypassed by prestart cancellation'

make_case dirty
printf 'preserve\n' > "$H/projects/app/unlanded.txt"
OUT=$(run_control); RC=$?
[ "$RC" -ne 0 ] || fail 'a dirty primary project was accepted'
[ ! -e "$D/keys" ] || fail 'a dirty project sent input'
assert_grep preserve "$H/projects/app/unlanded.txt" 'unlanded work was changed'
pass 'unlanded primary-project changes are preserved'

make_case stuck
OUT=$(run_control) || fail "stuck fixture initial snapshot failed: $OUT"
PROOF=$(printf '%s' "$OUT" | jq -er .proof) || fail 'stuck fixture proof missing'
printf 'stuck\n' > "$D/fault"
OUT=$(run_control --if-match "$PROOF"); RC=$?
[ "$RC" -ne 0 ] || fail 'an unproved stop was reported successful'
[ "$(wc -l < "$D/keys" | tr -d ' ')" = 1 ] || fail 'failed postcondition escalated to more input'
pass 'failed stop verification refuses without escalating or closing the pane'
