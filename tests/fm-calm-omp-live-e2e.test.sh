#!/usr/bin/env bash
# Token-free /calm-omp checks against the actual installed OMP CLI in an isolated
# tmux server and agent profile. No credentials or real Firstmate state are used.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_CALM_OMP_LIVE_E2E omp bun tmux python3
TMP_ROOT=$(fm_test_tmproot fm-calm-omp)
SOCKET="fm-calm-omp-$$"
cleanup() { tmux -L "$SOCKET" kill-server 2>/dev/null || true; fm_test_cleanup; }
trap cleanup EXIT
mkdir -p "$TMP_ROOT/project/.omp/extensions" "$TMP_ROOT/project/.pi/extensions/lib" "$TMP_ROOT/profile"
mkdir -p "$TMP_ROOT/project/.omp/extensions/lib"
cp "$ROOT/.omp/extensions/lib/fm-calm-omp-presentation.ts" "$TMP_ROOT/project/.omp/extensions/lib/"
cp "$ROOT/.omp/extensions/lib/fm-calm-omp-working-ship.ts" "$TMP_ROOT/project/.omp/extensions/lib/"
cp "$ROOT/.omp/extensions/fm-calm-omp.ts" "$TMP_ROOT/project/.omp/extensions/calm.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-working-ship.ts" "$TMP_ROOT/project/.pi/extensions/lib/"
cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$TMP_ROOT/project/.pi/extensions/lib/"
mkdir -p "$TMP_ROOT/project/bin"
cp "$ROOT/bin/fm-operational-input.sh" "$TMP_ROOT/project/bin/"
cp "$ROOT/tests/fixtures/calm-omp/probe.ts" "$TMP_ROOT/project/probe.ts"
OMP_BIN=$(command -v omp)
OMP_PACKAGE=$(python3 -c 'import os,sys; print(os.path.dirname(os.path.dirname(os.path.realpath(sys.argv[1]))))' "$OMP_BIN")
mkdir -p "$TMP_ROOT/project/node_modules/@oh-my-pi" "$TMP_ROOT/project/node_modules/@earendil-works"
ln -s "$(dirname "$(dirname "$OMP_PACKAGE")")/@oh-my-pi/pi-tui" "$TMP_ROOT/project/node_modules/@earendil-works/pi-tui"
ln -s "$(dirname "$(dirname "$OMP_PACKAGE")")/@oh-my-pi" "$TMP_ROOT/project/node_modules/@oh-my-pi-packages"
VERSION=$(omp --version 2>/dev/null | head -1)
# Unit behavior uses only the public extension registration and command handler.
EXT="$TMP_ROOT/project/.omp/extensions/calm.ts" bun - <<'JS' || fail 'calm-omp command capability checks failed'
import assert from 'node:assert/strict';
const {default:extension}=await import(process.env.EXT);
let command; extension({on(){},registerCommand(name,c){assert.equal(name,'calm-omp');command=c;}});
let focused, count=0, mounted=false, late, mode='normal'; const notices=[];
const ctx={hasUI:true,ui:{notify:(...args)=>notices.push(args),setWidget:(key,factory)=>{
 if (!factory) {mounted=false;if(mode==='cleanup-fails')throw Error();return;}
 mounted=true;if(mode==='async'){late=factory;return;} if(mode==='factory-fails')throw Error();
 assert.deepEqual(factory({getFocused:()=>focused}).render(80),[]);
}}};
focused={onToggleToolActivity(){assert.equal(this,focused);assert.equal(mounted,false);count++;}};
await command.handler('',ctx); assert.equal(count,1);
focused={onToggleToolActivity(){count+=2;}};await command.handler('',ctx);assert.equal(count,3);
for (const m of ['async','factory-fails','cleanup-fails']){mode=m;await command.handler('',ctx);assert.equal(count,3);}
late({getFocused:()=>focused});assert.equal(count,3);
mode='normal';focused={};await command.handler('',ctx);assert.match(notices.at(-1)[0],/unavailable/);
ctx.hasUI=false;await command.handler('',ctx);assert.match(notices.at(-1)[0],/interactive/);
ctx.hasUI=true;await command.handler('on',ctx);assert.match(notices.at(-1)[0],/Usage/);
focused={onToggleToolActivity(){throw Error();}};await command.handler('',ctx);assert.equal(notices.at(-1)[1],'error');
console.log('ok - capability failures, fresh editor lookup, receiver, probe cleanup and delayed factory safety');

const originalSetInterval=globalThis.setInterval, originalClearInterval=globalThis.clearInterval;
const clocks=new Map(); let clockId=0;
globalThis.setInterval=(fn)=>{const id=++clockId;clocks.set(id,fn);return id;};
globalThis.clearInterval=(id)=>clocks.delete(id);
try {
 const events=new Map(), widgets=new Map(); let hidden=true, redraws=0;
 const live={hasUI:true,ui:{notify:(...args)=>notices.push(args),setWidget:(key,factory)=>{
  widgets.get(key)?.dispose?.();widgets.delete(key);
  if(factory)widgets.set(key,factory({requestRender(){redraws++;}}));
 }}};
 extension({pi:{settings:{get:()=>hidden}},on:(name,handler)=>events.set(name,handler),registerCommand(){}});
 const emit=(name,event={})=>events.get(name)(event,live);
 const boat=()=>widgets.get('firstmate-calm-omp-working-ship');
 emit('session_start');emit('agent_start');if(clocks.size!==1) throw Error(`timer=${clocks.size} boat=${!!boat()} events=${[...events.keys()]}`);assert.ok(boat());
 const first=boat();first.render(40);for(let i=0;i<4;i++)for(const tick of clocks.values())tick();
 assert.ok(redraws>0);const frozen=first.render(40);
 emit('agent_end',{willContinue:true});emit('agent_start');assert.equal(boat(),first);
 hidden=false;for(const tick of clocks.values())tick();assert.equal(boat(),undefined);assert.deepEqual(first.render(40),[]);
 hidden=true;for(const tick of clocks.values())tick();assert.deepEqual(boat().render(40),frozen);
 emit('agent_end');assert.equal(boat(),undefined);assert.equal(clocks.size,0);
 emit('agent_start');assert.deepEqual(boat().render(40),frozen);emit('session_shutdown');assert.equal(clocks.size,0);assert.equal(boat(),undefined);
 hidden=undefined;emit('agent_start');for(const tick of clocks.values())tick();
 assert.ok(notices.filter(([message])=>message.includes('working boat is disabled')).length <= 1);
 assert.equal(boat(),undefined);emit('session_shutdown');
 live.hasUI=false;emit('agent_start');assert.equal(clocks.size,0);emit('session_shutdown');
 console.log('ok - single animation timer, continuation continuity, native preference sync, frozen resume, terminal/shutdown cleanup and unsupported settings');
} finally {globalThis.setInterval=originalSetInterval;globalThis.clearInterval=originalClearInterval;}

const {installCalmOmpPresentation}=await import(new URL('./lib/fm-calm-omp-presentation.ts', `file://${process.env.EXT}`));
const {encodeFirstmateOperationalInput}=await import(new URL('../../.pi/extensions/lib/fm-operational-input.ts', `file://${process.env.EXT}`));
let quiet=true;
const existing={role:'user',content:encodeFirstmateOperationalInput('watcher','existing wake')};
const existingCard={render:()=>['existing wake']};
const presMode={hideToolActivity:true,chatContainer:{children:[existingCard]},todoContainer:{render:()=>['todo']},renderCompactStatusLine:(_,lines)=>[...lines,'todo'],viewSession:{messages:[existing]},transcriptMessageComponents:new WeakMap([[existing,existingCard]]),addMessageToChat(message){this.chatContainer.children.push({render:()=>[JSON.stringify(message)]});return [];}};
presMode.todoContainer.mode=presMode;
const tui={children:[presMode.todoContainer],resetDisplay(){}};
const originalAdd=presMode.addMessageToChat;
const dispose=installCalmOmpPresentation(tui,()=>quiet);
assert.deepEqual(existingCard.render(),[]);
const wake=encodeFirstmateOperationalInput('watcher','new wake');
const check=(message,hide)=>{presMode.addMessageToChat(message);assert.equal(presMode.chatContainer.children.at(-1).render(80).length===0,hide);};
check({role:'user',content:[{type:'text',text:wake}]},true);
check({role:'user',content:'FIRSTMATE_OP: v1 watcher: quoted prose'},false);
check({role:'user',content:`Please explain ${wake}`},false);
check({role:'assistant',content:wake},false);
check({role:'custom',customType:'fm-main-mirror',content:wake},false);
check({role:'user',content:[{type:'text',text:wake},{type:'image',data:'x'}]},false);
check({role:'custom',customType:'advisor',content:'note'},true);
quiet=false;assert.deepEqual(existingCard.render(),['existing wake']);
quiet=true;dispose();dispose();assert.equal(presMode.addMessageToChat,originalAdd);assert.deepEqual(existingCard.render(),['existing wake']);
assert.equal(existing.content,encodeFirstmateOperationalInput('watcher','existing wake'));
console.log('ok - existing and new operational user rows hide, preserve captain prose/outcomes/attachments, and restore on disposal');

JS
cat > "$TMP_ROOT/start.sh" <<EOF2
#!/usr/bin/env bash
cd '$TMP_ROOT/project' || exit 1
export PI_CODING_AGENT_DIR='$TMP_ROOT/profile' CALM_LAB='$TMP_ROOT' OMP_SKIP_SETUP=1
unset FM_HOME FM_ROOT_OVERRIDE FM_CONFIG_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE
exec '$OMP_BIN' --no-extensions --no-skills --no-session -e ./.omp/extensions/calm.ts -e ./probe.ts --model calm-fixture/fixture --auto-approve
EOF2
start() { tmux -L "$SOCKET" new-session -d -s calm -x 120 -y 55 "bash '$TMP_ROOT/start.sh'"; }
send() { tmux -L "$SOCKET" send-keys -t calm -l "$1"; tmux -L "$SOCKET" send-keys -t calm Enter; }
wait_text() {
  local text=$1 i=0
  while [ "$i" -lt 200 ]; do
    tmux -L "$SOCKET" capture-pane -p -t calm > "$TMP_ROOT/screen" 2>/dev/null || true
    if grep -Fq "$text" "$TMP_ROOT/screen"; then return 0; fi
    sleep .1; i=$((i+1))
  done
  cat "$TMP_ROOT/screen" >&2; fail "OMP $VERSION did not show $text"
}
wait_phase() {
  local expected=$1 i=0
  while [ "$i" -lt 200 ]; do
    [ "$(cat "$TMP_ROOT/phase" 2>/dev/null)" = "$expected" ] && return 0
    sleep .1; i=$((i+1))
  done
  tmux -L "$SOCKET" capture-pane -p -t calm >&2
  fail "OMP $VERSION did not reach phase $expected (actual: $(cat "$TMP_ROOT/phase" 2>/dev/null))"
}
assert_no_boat() {
  tmux -L "$SOCKET" capture-pane -p -t calm > "$TMP_ROOT/screen"
  ! grep -Fq '╲▁▁▁╱' "$TMP_ROOT/screen" || fail "OMP $VERSION left a boat $1"
}
probe() { send "/calm-probe $1"; wait_text "PROBE_SAVED_$1"; }
start
sleep 2
send 'run the fixture'
wait_phase 1:idle
wait_text CALM_FIXTURE_COMPLETE
assert_no_boat 'while disabled'
probe visible
send /calm-omp
wait_text 'Tool activity: hidden'
probe hidden
send 'run the fixture again'
wait_text '╲▁▁▁╱'
cp "$TMP_ROOT/screen" "$TMP_ROOT/boat-first"
sleep 1
tmux -L "$SOCKET" capture-pane -p -t calm > "$TMP_ROOT/boat-second"
[ "$(grep -F '╲▁▁▁╱' "$TMP_ROOT/boat-first")" != "$(grep -F '╲▁▁▁╱' "$TMP_ROOT/boat-second")" ] || fail "OMP $VERSION boat did not animate"
wait_phase 2:continuation
# The follow-up model request is still part of the tool-using agent run.
for _ in 1 2 3 4; do
  tmux -L "$SOCKET" capture-pane -p -t calm > "$TMP_ROOT/screen"
  [ "$(grep -Fc '╲▁▁▁╱' "$TMP_ROOT/screen")" -eq 1 ] || fail "OMP $VERSION lost or duplicated the boat during continuation"
  sleep .15
done
wait_phase 2:idle
sleep .3
assert_no_boat 'after settling'
probe newhidden
send /calm-omp
wait_text 'Tool activity: visible'
probe restored
send /calm-omp
wait_text 'Tool activity: hidden'
sleep 1
tmux -L "$SOCKET" kill-session -t calm
start
sleep 2
send 'run the persisted fixture'
wait_phase 1:model
wait_text '╲▁▁▁╱'
wait_phase 1:idle
wait_text CALM_FIXTURE_COMPLETE
sleep .3
assert_no_boat 'after persisted run'
probe persisted
LAB="$TMP_ROOT" python3 - <<'PY' || fail "OMP $VERSION native visibility assertions failed"
import json,os
p=os.environ['LAB']
def load(n): return json.load(open(f'{p}/{n}.json'))
v,h,n,r,persist=[load(n) for n in ['visible','hidden','newhidden','restored','persisted']]
def rows(x): return [c for c in x['components'] if c.get('tool')]
assert rows(v) and any(c['lines'] for c in rows(v)),v['components']
for x in [h,n,persist]: assert rows(x) and all(not c['lines'] for c in rows(x)),x['components']
assert len(rows(n))>len(rows(h)), 'new model tool must actually execute while hidden'
assert rows(r) and all(c['lines'] for c in rows(r)),r['components']
def messages(x): return [e for e in x['entries'] if e.get('type')=='message']
assert messages(v)==messages(h), 'toggle changed stored messages'
assert messages(n)==messages(r), 'restoration changed stored messages'
assert v['tools']==h['tools']==r['tools'] and v['active']==r['active'], 'tools were replaced'
print('ok - existing/new tool rows zero height, restoration, native profile persistence, unchanged session messages and tool registry')
PY
# Advisor cards and both native TODO layouts follow the same presentation setting.
send '/calm-setting false'
wait_text SETTING_false
send '/calm-advisor EXISTING'
wait_text ADVISOR_SAVED_EXISTING
send '/calm-operational EXISTING'
wait_text OPERATIONAL_SAVED_EXISTING
send /calm-todo
wait_text TODO_SAVED
probe extras-visible
send '/calm-setting true'
wait_text SETTING_true
probe extras-hidden
send '/calm-advisor NEW'
wait_text ADVISOR_SAVED_NEW
send '/calm-operational NEW'
wait_text OPERATIONAL_SAVED_NEW
probe extras-newhidden
tmux -L "$SOCKET" resize-window -t calm -x 100 -y 20
sleep .3
probe extras-compact-hidden
tmux -L "$SOCKET" resize-window -t calm -x 120 -y 55
sleep .3
send '/calm-setting false'
wait_text SETTING_false
probe extras-restored
LAB="$TMP_ROOT" python3 - <<'PYEXTRA' || fail "OMP $VERSION advisor/TODO presentation assertions failed"
import json,os
p=os.environ['LAB']
def load(n): return json.load(open(f'{p}/extras-{n}.json'))
v,h,n,ch,r=[load(n) for n in ['visible','hidden','newhidden','compact-hidden','restored']]
def flat(lines): return '\n'.join(lines)
assert 'WAKE_EXISTING' in flat(v['presentation']['chat'])
assert 'ADVISOR_EXISTING' in flat(v['presentation']['chat'])
assert 'CALM_TODO_TASK' in flat(v['presentation']['todo'])
for x in [h,n,ch]:
    view=x['presentation']
    assert view['advisors'] and all(not lines for lines in view['advisors']), view
    assert view['operational'] and all(not lines for lines in view['operational']), view
    assert 'WAKE_EXISTING' not in flat(view['chat']) and 'WAKE_NEW' not in flat(view['chat'])
    assert 'CAPTAIN_EXISTING' in flat(view['chat']) and 'OUTCOME_EXISTING' in flat(view['chat'])
    assert view['todo']==[],view
    assert view['compact']==['WORKING_SENTINEL'],view
    assert 'ADVISOR_EXISTING' not in flat(view['chat']) and 'ADVISOR_NEW' not in flat(view['chat'])
    assert 'CALM_FIXTURE_COMPLETE' in flat(view['chat'])
assert len(n['presentation']['advisors'])>len(h['presentation']['advisors'])
assert 'WAKE_EXISTING' in flat(r['presentation']['chat']) and 'WAKE_NEW' in flat(r['presentation']['chat'])
assert 'ADVISOR_NEW' in flat(r['presentation']['chat'])
assert 'CALM_TODO_TASK' in flat(r['presentation']['todo'])
for x in [h,n,ch,r]:
    assert x['presentation']['phases']==v['presentation']['phases']
    assert x['presentation']['storedPhases']==v['presentation']['storedPhases']
def messages(x): return [e for e in x['entries'] if e.get('type')=='message']
assert messages(v)==messages(h)
assert messages(n)==messages(ch)==messages(r)
print('ok - existing/new advisor cards and full/compact TODO hide, restore, preserve answers, working content and session state')
PYEXTRA
send 'run the abort fixture'
wait_text '╲▁▁▁╱'
send '/calm-setting false'
wait_text SETTING_false
sleep .4
assert_no_boat 'after native preference disabled during work'
send '/calm-setting true'
wait_text SETTING_true
wait_text '╲▁▁▁╱'
tmux -L "$SOCKET" send-keys -t calm Escape
wait_phase 2:idle
sleep .3
assert_no_boat 'after abort'
pass "OMP $VERSION actual CLI /calm-omp native visibility and animated boat lifecycle"
