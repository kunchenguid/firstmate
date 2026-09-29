#!/usr/bin/env bash
# Token-free Pi/Herdr attention guard: real question components, installed Pi,
# generated Herdr reporter, and tracked primary extension in an isolated home.
# The fixture reporter proves pane state only, never live Telegram delivery.
# A local provider supplies tool calls; a result barrier exposes the submit gap.
# FM_PI_BIN, FM_PI_ASK_USER_EXTENSION, FM_PI_PLAN_QUESTION_MODULE select installs.
# FM_HERDR_LAB_HELPER selects the guarded lifecycle helper, never raw Herdr.
# FM_HERDR_LAB_TASK overrides the helper's session-name seed.
# FM_ATTENTION_TEST_KEEP=1 retains captures/events in the printed fixture path.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_PI_HERDR_ATTENTION_LIVE herdr "${FM_PI_BIN:-pi}" jq node
ask=${FM_PI_ASK_USER_EXTENSION:-"$HOME/.pi/agent/git/github.com/ghoseb/pi-askuserquestion/src/index.ts"}
plan=${FM_PI_PLAN_QUESTION_MODULE:-"$HOME/.pi/agent/npm/node_modules/@narumitw/pi-plan-mode/src/question-tool.ts"}
for module in "$ask" "$plan"; do
  if [ ! -f "$module" ]; then
    if [ "${FM_PI_HERDR_ATTENTION_LIVE:-${FM_LIVE:-0}}" = 1 ]; then fail "question module absent: $module"; fi
    printf 'skip: question module absent: %s\n' "$module"
    exit 0
  fi
done
HERDR_LAB_HELPER=${FM_HERDR_LAB_HELPER:-"$ROOT/bin/fm-herdr-lab.sh"}
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name "${FM_HERDR_LAB_TASK:-pi-decision-attention}")
fixture=
wait_pid=
cleanup() {
  local status=$?
  if [ -n "$wait_pid" ]; then kill "$wait_pid" 2>/dev/null || true; wait "$wait_pid" 2>/dev/null || true; fi
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  if [ -n "$fixture" ]; then
    if [ "${FM_ATTENTION_TEST_KEEP:-0}" = 1 ]; then printf '# fixture: %s\n' "$fixture"; else rm -rf "$fixture"; fi
  fi
  fm_test_cleanup
  exit "$status"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
lab() { "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
fixture=$(mktemp -d "${TMPDIR:-/tmp}/fm-pi-attention.XXXXXX")
fixture=$(cd "$fixture" && pwd -P)
mkdir -p "$fixture/home/.pi/agent/extensions" "$fixture/home/state" "$fixture/home/config" "$fixture/repo/.pi" "$fixture/repo/bin" "$fixture/pi"
lab status --json > "$fixture/versions.json"
pi_version=$("${FM_PI_BIN:-pi}" --version)
printf '# Pi %s; Herdr %s (protocol %s)\n' "$pi_version" "$(jq -r .server.version "$fixture/versions.json")" "$(jq -r .server.protocol "$fixture/versions.json")"
if ! command -v pi-signed >/dev/null; then printf '# pi-signed unavailable; separate launcher not exercised\n'; fi
HOME="$fixture/home" lab integration install pi > "$fixture/integration.txt"
cp -R "$ROOT/.pi/extensions" "$fixture/repo/.pi/"
cp "$ROOT/bin/fm-operational-input.sh" "$fixture/repo/bin/"
cat > "$fixture/repo/bin/fm-watch-arm.sh" <<'ARM'
#!/usr/bin/env bash
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=attention-lab\n' "$$"
exec sleep 300
ARM
chmod +x "$fixture/repo/bin/fm-watch-arm.sh"
# Resolve source module paths without shell interpolation into TypeScript.
ASK="$ask" PLAN="$plan" FIXTURE="$fixture" node --input-type=module <<'JS'
import fs from 'node:fs';
const fixture = process.env.FIXTURE;
const imports = `import ask from ${JSON.stringify(process.env.ASK)};\nimport {PLAN_MODE_QUESTION_PARAMS,answerPlanModeQuestions} from ${JSON.stringify(process.env.PLAN)};\n`;
fs.writeFileSync(fixture+'/proof.ts', imports + `
import watch from './repo/.pi/extensions/fm-primary-pi-watch.ts';
import {createAssistantMessageEventStream} from '@earendil-works/pi-ai';
import {appendFileSync,writeFileSync} from 'node:fs';
export default function(pi) {
  watch(pi);
  pi.on('before_agent_start',()=>writeFileSync(process.env.FM_HOME+'/state/.lock',String(process.pid)+'\\n'));
  ask(pi);
  pi.registerTool({name:'plan_mode_question',label:'Plan question',description:'Real plan question component',parameters:PLAN_MODE_QUESTION_PARAMS,
    execute: (_id,input,_signal,_update,ctx) => answerPlanModeQuestions(input.questions,ctx,{isCurrent:()=>true,isEnabled:()=>true})});
  let scenario = 'single', release, next = 0;
  const log = value => appendFileSync(process.env.FM_HOME+'/events.jsonl',JSON.stringify(value)+'\\n');
  pi.registerCommand('attention-case',{description:'Select a local proof case', handler:async(args)=>{scenario=args;pi.sendUserMessage('ATTENTION '+args);}});
  pi.registerCommand('attention-resume',{description:'Release result barrier',handler:async()=>{release?.();release=undefined;}});
  pi.events.on('herdr:blocked', data => log({event:'herdr:blocked',data}));
  for(const name of ['session_start','turn_start','agent_settled']) pi.on(name,(_e,ctx)=>log({event:name,session:ctx.sessionManager.getSessionId(),idle:ctx.isIdle()}));
  pi.on('tool_call',(event,ctx)=>log({event:'tool_call',id:event.toolCallId,session:ctx.sessionManager.getSessionId()}));
  pi.on('tool_result',async(event)=>{
    log({event:'tool_result',id:event.toolCallId,details:event.details});
    await new Promise(resolve=>{release=resolve;});
  });
  pi.registerProvider('attention-proof',{
    apiKey:'test-only',baseUrl:'http://127.0.0.1/unused',api:'attention-proof-api',
    models:[{id:'local',name:'Local attention proof',reasoning:false,input:['text'],cost:{input:0,output:0,cacheRead:0,cacheWrite:0},contextWindow:4096,maxTokens:128}],
    streamSimple(model,context) {
      const stream=createAssistantMessageEventStream();
      const afterTool=context.messages.at(-1)?.role==='toolResult';
      const output={role:'assistant',content:[],api:model.api,provider:model.provider,model:model.id,
        usage:{input:0,output:0,cacheRead:0,cacheWrite:0,totalTokens:0,cost:{input:0,output:0,cacheRead:0,cacheWrite:0,total:0}},stopReason:afterTool?'stop':'toolUse',timestamp:Date.now()};
      queueMicrotask(()=>{
        stream.push({type:'start',partial:output});
        const questions=Array.from({length:scenario==='single'?1:2},(_,i)=>({
          ...(scenario==='plan'?{id:'q'+i}:{multiSelect:false}),header:'Question '+i,question:'Choose value '+i,
          options:[{label:'Alpha',description:'First option'},{label:'Beta',description:'Second option'}]}));
        output.content.push(afterTool?{type:'text',text:'ATTENTION_SETTLED'}:{type:'toolCall',id:'proof-'+ ++next,name:scenario==='plan'?'plan_mode_question':'ask_user_question',arguments:{questions}});
        stream.push({type:'done',reason:output.stopReason,message:output});stream.end();
      });
      return stream;
    }
  });
}
`);
JS
lab workspace create --label attention-proof --cwd "$fixture/repo" > "$fixture/workspace.json"
pane=$(jq -r '.result.root_pane.pane_id' "$fixture/workspace.json")
printf -v launch 'env FM_HOME=%q PI_CODING_AGENT_DIR=%q %q --approve --offline --no-extensions --no-skills --no-prompt-templates --no-context-files --no-session --provider attention-proof --model local -e %q -e %q' "$fixture/home" "$fixture/pi" "${FM_PI_BIN:-pi}" "$fixture/home/.pi/agent/extensions/herdr-agent-state.ts" "$fixture/proof.ts"
lab pane run "$pane" "$launch" >/dev/null
count() { [ -f "$fixture/home/events.jsonl" ] && jq -s --arg event "$1" '[.[]|select(.event==$event)]|length' "$fixture/home/events.jsonl" || echo 0; }
wait_event() {
  local i
  for ((i=0;i<150;i++)); do [ "$(count "$1")" -ge "$2" ] && return; sleep .1; done
  lab pane read "$pane" >&2
  fail "Pi $pi_version: missing event $1 count $2"
}
status() { lab agent get "$pane" | jq -r '.result.agent.agent_status'; }
expect_state() {
  local i actual
  for ((i=0;i<100;i++)); do actual=$(status); [ "$actual" = "$1" ] && { printf '%s=%s\n' "$2" "$actual"; return; }; sleep .1; done
  fail "Pi $pi_version: $2 expected $1 got $actual"
}
wait_form() {
  local i
  for ((i=0;i<100;i++)); do
    lab pane read "$pane" > "$fixture/$1.txt"
    grep -Fq "$2" "$fixture/$1.txt" && return
    sleep .1
  done
  fail "Pi $pi_version: form never displayed $2"
}
send_command() { lab pane send-text "$pane" "$1" >/dev/null; lab pane send-keys "$pane" Enter >/dev/null; }
key() { lab pane send-keys "$pane" "$1" >/dev/null; }
wait_event session_start 1
expect_state idle startup
lab agent wait "$pane" --until blocked --timeout 15000 > "$fixture/attention-wait.json" &
wait_pid=$!
send_command '/attention-case single'
wait_event tool_call 1
expect_state blocked single-open
wait "$wait_pid"
wait_pid=
jq -e --arg pane "$pane" '.result.agent.agent_status == "blocked" and .result.agent.pane_id == $pane' "$fixture/attention-wait.json" >/dev/null
printf 'agent-wait=blocked\n'
key Enter
wait_event tool_result 1
expect_state blocked single-submit-gap
send_command '/attention-resume'
wait_event agent_settled 1
expect_state idle single-settled
send_command '/attention-case multi'
wait_event tool_call 2
expect_state blocked multi-open
wait_form multi 'Choose value 0'
key Right
wait_form tab 'Choose value 1'
expect_state blocked multi-tab
key Left
key Enter
key Enter
key Enter
wait_event tool_result 2
expect_state blocked multi-submit-gap
send_command '/attention-resume'
wait_event agent_settled 2
expect_state idle multi-settled
send_command '/attention-case multi'
wait_event tool_call 3
key Escape
wait_event tool_result 3
expect_state blocked cancel-gap
send_command '/attention-resume'
wait_event agent_settled 3
expect_state blocked cancel-unresolved
# The same real form reopens. Its answers close the outstanding decision.
send_command '/attention-case multi'
wait_event tool_call 4
expect_state blocked reopened
key Enter
key Enter
key Enter
wait_event tool_result 4
expect_state blocked reopened-submit-gap
send_command '/attention-resume'
wait_event agent_settled 4
expect_state idle resolved
send_command '/attention-case plan'
wait_event tool_call 5
expect_state blocked plan-open
key Escape
wait_event tool_result 5
send_command '/attention-resume'
wait_event agent_settled 5
expect_state blocked plan-cancel-unresolved
send_command '/new'
wait_event session_start 2
expect_state idle session-recovery
send_command '/attention-case single'
wait_event tool_call 6
expect_state blocked replacement-session-open
key Enter
wait_event tool_result 6
send_command '/attention-resume'
wait_event agent_settled 6
expect_state idle replacement-session-settled
EVENTS="$fixture/home/events.jsonl" PANE="$pane" node --input-type=module <<'JS'
import fs from 'node:fs';
import assert from 'node:assert/strict';
const events=fs.readFileSync(process.env.EVENTS,'utf8').trim().split('\n').map(JSON.parse);
const holds=events.filter(x=>x.event==='herdr:blocked').map(x=>x.data);
assert.deepEqual(holds.map(x=>x.active),[true,false,true,false,true,false,true,false,true,false]);
const root=events.find(x=>x.event==='session_start').session;
assert(holds.every(x=>x.identity.kind==='root' && x.identity.paneId===process.env.PANE));
assert(holds.slice(0,8).every(x=>x.identity.sessionId===root));
assert(holds.slice(8).every(x=>x.identity.sessionId===events.filter(x=>x.event==='session_start')[1].session));
assert.equal(new Set(holds.map(x=>x.identity.generation)).size,2);
assert(events.filter(x=>x.event==='tool_result').every(x=>typeof x.details.cancelled==='boolean'));
console.log('ok - real question lifecycle, balanced holds, exact root identity, and authoritative recovery');
JS
pass "Pi $pi_version: token-free Herdr attention integration"
