#!/usr/bin/env bash
# Opt-in native OpenCode v2 worker launch on a private tmux socket, FM_HOME,
# database, and local model endpoint. No managed credentials or service touched.
set -eu

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
fm_live_gate opt-in FM_OPENCODE_WORKER_LIVE opencode tmux python3
OPENCODE_BIN=$(command -v opencode)
TMUX_BIN=$(command -v tmux)
VERSION=$("$OPENCODE_BIN" --version)
case "$VERSION" in
  2.* | 'opencode v2.'*) ;;
  *) fail "OpenCode worker v2 guard requires major 2, installed: $VERSION" ;;
esac
LAB=$(fm_test_tmproot fm-opencode-worker-live)
SOCKET="fm-opencode-worker-live-$$"
ID="opencode-live-$$"
SERVER_PID=
cleanup() {
  "$TMUX_BIN" -L "$SOCKET" kill-server 2>/dev/null || true
  [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT
fm_test_spawn_home "$LAB/home" opencode
fm_git_worktree "$LAB/project" "$LAB/wt" worker-live
fm_test_spawn_brief "$LAB/home" "$ID" 'Reply exactly NATIVE_WORKER_OK. Do not use tools.'
cat > "$LAB/model.py" <<'PY'
import http.server, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
class Model(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['content-length'])))
        with (root / 'requests.jsonl').open('a') as out:
            out.write(json.dumps(body) + '\n')
        self.send_response(200)
        if not body.get('stream'):
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            response = {'id': 'fixture', 'object': 'chat.completion', 'created': 0,
                        'model': 'z-ai/glm-5.3', 'choices': [{'index': 0,
                        'message': {'role': 'assistant', 'content': 'NATIVE_WORKER_OK'},
                        'finish_reason': 'stop'}],
                        'usage': {'prompt_tokens': 0, 'completion_tokens': 0, 'total_tokens': 0}}
            self.wfile.write(json.dumps(response).encode())
            return
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()
        chunk = {'id': 'fixture', 'object': 'chat.completion.chunk',
                 'model': 'z-ai/glm-5.3', 'choices': [{'index': 0,
                 'delta': {'content': 'NATIVE_WORKER_OK'}, 'finish_reason': None}]}
        self.wfile.write(('data: ' + json.dumps(chunk) + '\n\n').encode())
        chunk['choices'][0].update(delta={}, finish_reason='stop')
        self.wfile.write(('data: ' + json.dumps(chunk) + '\n\ndata: [DONE]\n\n').encode())
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Model)
(root / 'port').write_text(str(server.server_port))
server.serve_forever()
PY
python3 "$LAB/model.py" "$LAB" > "$LAB/server.log" 2>&1 &
SERVER_PID=$!
for ((i=0; i<100; i++)); do
  [ ! -s "$LAB/port" ] || break
  sleep 0.1
done
[ -s "$LAB/port" ] || fail "$VERSION: local model fixture did not start"
PORT=$(cat "$LAB/port")
cat > "$LAB/wt/opencode.json" <<EOF
{"model":"nvidia/z-ai/glm-5.3","provider":{"nvidia":{"options":{"apiKey":"fixture-only","baseURL":"http://127.0.0.1:$PORT/v1"}}}}
EOF
printf '/opencode.json\n' >> "$(git -C "$LAB/wt" rev-parse --git-path info/exclude)"
FAKEBIN=$(fm_test_make_spawn_fakebin "$LAB/tools")
cat > "$FAKEBIN/tmux" <<EOF
#!/usr/bin/env bash
exec '$TMUX_BIN' -L '$SOCKET' "\$@"
EOF
cat > "$FAKEBIN/opencode" <<EOF
#!/usr/bin/env bash
export XDG_CONFIG_HOME='$LAB/xdg/config' XDG_DATA_HOME='$LAB/xdg/data'
export XDG_STATE_HOME='$LAB/xdg/state' XDG_CACHE_HOME='$LAB/xdg/cache'
export OPENCODE_DB='$LAB/opencode.db' TMPDIR='$LAB/tmp'
exec '$OPENCODE_BIN' "\$@"
EOF
cat > "$FAKEBIN/treehouse" <<EOF
#!/usr/bin/env bash
printf "cd '%s'\\n" '$LAB/wt'
EOF
chmod +x "$FAKEBIN/tmux" "$FAKEBIN/opencode" "$FAKEBIN/treehouse"
mkdir -p "$LAB/tmp" "$LAB/user-home"
cat > "$LAB/bashrc" <<EOF
export PATH='$FAKEBIN':\$PATH
treehouse() { cd '$LAB/wt'; }
EOF
HOME="$LAB/user-home" PATH="$FAKEBIN:$PATH" "$TMUX_BIN" -L "$SOCKET" new-session -d -s firstmate -c "$LAB/wt"
"$TMUX_BIN" -L "$SOCKET" set-option -g default-command "bash --noprofile --rcfile '$LAB/bashrc' -i"
if ! fm_test_run_spawn "$LAB/home" "$LAB/wt" "$FAKEBIN" "$ID" "$LAB/project" --harness opencode --model nvidia/z-ai/glm-5.3 --mode no-mistakes --yolo off > "$LAB/spawn.log"; then
  cat "$LAB/spawn.log" >&2
  cat "$LAB/server.log" >&2
  tail -30 "$LAB/xdg/data/opencode/log/opencode.log" >&2 || true
  "$TMUX_BIN" -L "$SOCKET" capture-pane -p -t "firstmate:fm-$ID" >&2 || true
  fail "$VERSION: native worker spawn failed"
fi
for ((i=0; i<200; i++)); do
  [ ! -f "$LAB/home/state/$ID.turn-ended" ] || break
  sleep 0.1
done
[ -f "$LAB/home/state/$ID.turn-ended" ] || fail "$VERSION: native execution completion did not notify Firstmate"
python3 - "$LAB" <<'PY'
import json, pathlib, sqlite3, sys
root = pathlib.Path(sys.argv[1])
requests = [json.loads(line) for line in (root / 'requests.jsonl').read_text().splitlines()]
assert requests and all(r['model'] == 'z-ai/glm-5.3' for r in requests), requests
db = sqlite3.connect(root / 'opencode.db')
models = [json.loads(r[0]) for r in db.execute('select model from session_v2 where model is not null')]
assert models and all(m['providerID'] == 'nvidia' and m['id'] == 'z-ai/glm-5.3' for m in models), models
users = [json.loads(r[0])['text'] for r in db.execute("select data from session_message where type='user'")]
assert len(users) == 1 and 'Read the brief at ' in users[0], users
assert any('NATIVE_WORKER_OK' in r[0] for r in db.execute("select data from session_message where type='assistant'"))
PY
HEAD_BEFORE=$(git -C "$LAB/wt" rev-parse HEAD)
printf 'preserve this uncommitted fixture work\n' > "$LAB/wt/uncommitted-sentinel"
if ! FM_ROOT_OVERRIDE='' FM_HOME="$LAB/home" HOME="$LAB/home/user-home" \
  PATH="$FAKEBIN:$PATH" FM_SPAWN_NO_GUARD=1 \
  bash "$ROOT/bin/fm-control.sh" "$ID" relaunch --note 'Resume the same fixture task after native launch recovery.' > "$LAB/relaunch.log" 2>&1; then
  cat "$LAB/relaunch.log" >&2
  fail "$VERSION: native control relaunch failed"
fi
[ "$(git -C "$LAB/wt" rev-parse HEAD)" = "$HEAD_BEFORE" ] || fail "$VERSION: relaunch changed worktree HEAD"
[ "$(cat "$LAB/wt/uncommitted-sentinel")" = 'preserve this uncommitted fixture work' ] || fail "$VERSION: relaunch discarded uncommitted work"
for ((i=0; i<200; i++)); do
  [ ! -f "$LAB/home/state/$ID.turn-ended" ] || break
  sleep 0.1
 done
[ -f "$LAB/home/state/$ID.turn-ended" ] || fail "$VERSION: relaunched worker did not notify completion"
python3 - "$LAB" <<'PYEND'
import json, pathlib, sqlite3, sys
root = pathlib.Path(sys.argv[1])
db = sqlite3.connect(root / 'opencode.db')
users = [json.loads(r[0])['text'] for r in db.execute("select data from session_message where type='user'")]
assert len(users) == 2 and all('Read the brief at ' in text for text in users), users
models = [json.loads(r[0]) for r in db.execute('select model from session_v2 where model is not null')]
assert len(models) == 2 and all(m['providerID'] == 'nvidia' and m['id'] == 'z-ai/glm-5.3' for m in models), models
PYEND
pass "$VERSION: exact GLM model, one brief pointer per launch, native completion and relaunch preserve worktree"
