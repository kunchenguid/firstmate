#!/usr/bin/env bash
# Real WebSocket framing against a local fake server, plus watcher fallback.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-t3-events)
mkdir -p "$TMP_ROOT/config" "$TMP_ROOT/state"
printf 'test-token\n' > "$TMP_ROOT/config/t3code-token"
cat > "$TMP_ROOT/server.cjs" <<'JS'
const http = require('node:http');
const fs = require('node:fs');
const crypto = require('node:crypto');
const root = process.argv[2];
const mode = () => fs.readFileSync(root + '/mode', 'utf8').trim();
const thread = (pending) => ({id:'owned',projectId:'project',session:{status:'running'},hasPendingUserInput:pending,modelSelection:{instanceId:'codex'}});
const server = http.createServer((req,res) => {
  const send = (code,data) => {res.writeHead(code,{'content-type':'application/json'});res.end(JSON.stringify(data));};
  if(req.url === '/.well-known/t3/environment') return send(200,{serverVersion:'0.0.41-nightly.20260914.1707',capabilities:{threadSettlement:true}});
  if(req.headers.authorization !== 'Bearer test-token') return send(401,{});
  if(req.url === '/api/orchestration/shell') return send(200,{projects:[],threads:[]});
  if(req.url === '/api/auth/websocket-ticket') return send(mode()==='denied'?403:200,{ticket:'ticket'});
  send(404,{});
});
function frame(value) {
  const data=Buffer.from(JSON.stringify(value));
  const header=Buffer.alloc(data.length < 126 ? 2 : 4);header[0]=0x81;
  if(data.length<126) header[1]=data.length;
  else {header[1]=126;header.writeUInt16BE(data.length,2);}
  return Buffer.concat([header,data]);
}
server.on('upgrade',(req,socket) => {
  if(req.url !== '/ws?wsTicket=ticket') return socket.destroy();
  const accept=crypto.createHash('sha1').update(req.headers['sec-websocket-key']+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
  socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: '+accept+'\r\n\r\n');
  socket.on('error',()=>{});
  let buffer=Buffer.alloc(0),started=false;
  socket.on('data',(bytes)=>{
    buffer=Buffer.concat([buffer,bytes]);
    if(started || buffer.length<6) return;
    let size=buffer[1]&127,offset=2;
    if(size===126){if(buffer.length<4)return;size=buffer.readUInt16BE(2);offset=4;}
    if(size===127 || buffer.length<offset+4+size)return;
    const mask=buffer.subarray(offset,offset+4),data=buffer.subarray(offset+4,offset+4+size);
    for(let i=0;i<data.length;i++)data[i]^=mask[i%4];
    const request=JSON.parse(data);
    if(request._tag!=='Request'||request.tag!=='orchestration.subscribeShell'||request.payload.requestCompletionMarker!==true)return socket.destroy();
    started=true;
    fs.appendFileSync(root+'/subscriptions','subscribed\n');
    const chunk=(values)=>socket.write(frame({_tag:'Chunk',requestId:'1',values}));
    const current=mode();
    if(current==='unacknowledged') return;
    if(current==='malformed') return socket.write(frame({_tag:'Chunk',requestId:'1',values:[{kind:'snapshot',snapshot:{}}]}));
    chunk([{kind:'snapshot',snapshot:{threads:current==='level'?[thread(true)]:[thread(false)]}}]);
    if(current==='drop') return socket.destroy();
    if(current==='edge') setTimeout(()=>chunk([{kind:'thread-upserted',thread:{...thread(true),id:'foreign'}},{kind:'thread-upserted',thread:thread(true)}]),40);
  });
});
server.listen(0,'127.0.0.1',()=>fs.writeFileSync(root+'/port',String(server.address().port)));
JS
printf 'edge\n' > "$TMP_ROOT/mode"
node "$TMP_ROOT/server.cjs" "$TMP_ROOT" &
SERVER_PID=$!
cleanup() { kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fm_test_cleanup; }
trap cleanup EXIT
for _ in $(seq 1 100); do [ ! -s "$TMP_ROOT/port" ] || break; sleep 0.1; done
[ -s "$TMP_ROOT/port" ] || fail 'fake T3 event server did not start'
FM_T3CODE_ORIGIN="http://127.0.0.1:$(cat "$TMP_ROOT/port")"
export FM_T3CODE_ORIGIN
export FM_CONFIG_OVERRIDE="$TMP_ROOT/config"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=bin/fm-transition-lib.sh
. "$ROOT/bin/fm-transition-lib.sh"
fm_backend_has_push t3code || fail 'T3 push must be dispatched'
fm_backend_events_capable t3code server || fail 'T3 event capability must accept the verified server'
record=$(fm_backend_wait_transition t3code server 2 "$TMP_ROOT/state" owned) || fail 'T3 blocked edge must wake'
[ "$(fm_transition_pane_id "$record")" = owned ] || fail 'foreign thread must not wake this home'
[ "$(fm_transition_to_status "$record")" = blocked ] || fail 'pending input must normalize to blocked'
[ "$(fm_transition_workspace_id "$record")" = project ] || fail 'project identity must survive normalization'
fm_backend_commit_transition t3code "$TMP_ROOT/state" server "$record"
printf 'level\n' > "$TMP_ROOT/mode"
rc=0
fm_backend_wait_transition t3code server 0.2 "$TMP_ROOT/state" owned >/dev/null || rc=$?
[ "$rc" -eq 1 ] || fail 'committed blocked level must dedupe and wait its full budget'
fm_backend_clear_transition t3code "$TMP_ROOT/state" owned
fm_backend_wait_transition t3code server 1 "$TMP_ROOT/state" owned >/dev/null || fail 'reconnect must reconcile an already blocked thread'
for mode in drop denied malformed unacknowledged; do
  printf '%s\n' "$mode" > "$TMP_ROOT/mode"
  rc=0
  fm_backend_wait_transition t3code server 0.2 "$TMP_ROOT/state" owned >/dev/null || rc=$?
  [ "$rc" -eq 2 ] || fail "$mode must select polling fallback, got $rc"
done
pass 'T3 WebSocket subscription, thread filtering, normalization, reconnect, dedupe, and failure fallback'

# Exercise the real watcher boundary with this HTTP/WebSocket server. Only the
# final sleep/wake callbacks are replaced so fallback budgets remain observable.
set +e  # The watcher handles nonzero classification verdicts explicitly.
export FM_STATE_OVERRIDE="$TMP_ROOT/state" FM_ROOT_OVERRIDE="$ROOT"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-watch.sh"
POLL=1
EVENT_CAP_FAIL_MAX=2
fm_write_meta "$STATE/owned.meta" 'window=fm-owned' 't3_thread_id=owned' 'backend=t3code' 'kind=ship'
fm_write_meta "$STATE/second.meta" 'window=fm-second' 't3_thread_id=second' 'backend=t3code' 'kind=secondmate'
printf 'edge\n' > "$TMP_ROOT/mode"
WAKE_LOG="$TMP_ROOT/wakes"
SLEEP_LOG="$TMP_ROOT/sleeps"
# shellcheck disable=SC2329 # Callbacks invoked by the sourced watcher.
wake() { printf '%s\n' "$1" >> "$WAKE_LOG"; }
# shellcheck disable=SC2329
sleep() { printf '%s\n' "$1" >> "$SLEEP_LOG"; }
event_wait_or_sleep
assert_grep 't3code: agent blocked' "$WAKE_LOG" 'T3 event must reach the normal wake handler'
assert_grep 'stale: owned ' "$WAKE_LOG" 'wake must use the thread id without a session prefix'
assert_grep 'owned' "$STATE/.wake-queue" 'T3 wake must be durable before dedupe commits'
[ "$(fm_backend_event_session t3code another-thread)" = server ] || fail 'all T3 threads must share the server subscription'
[ "$(fm_backend_transition_target herdr default w1:p2)" = default:w1:p2 ] || fail 'Herdr target reconstruction must stay unchanged'
printf 'denied\n' > "$TMP_ROOT/mode"
event_wait_or_sleep
event_wait_or_sleep
# shellcheck disable=SC2154 # Assigned and updated by the sourced watcher.
[ "$_event_cap_ok" = 0 ] || fail 'repeated socket failure must disable push for this watcher'
[ "$(wc -l < "$SLEEP_LOG" | tr -d ' ')" = 2 ] || fail 'every failed reader must sleep the original poll budget'
event_wait_or_sleep
[ "$(wc -l < "$SLEEP_LOG" | tr -d ' ')" = 3 ] || fail 'disabled event path must continue ordinary polling'
pass 'T3 watcher dispatch, durable wake, endpoint identity, and unchanged polling fallback'
