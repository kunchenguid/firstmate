#!/usr/bin/env bash
# tests/rex-fake-fixture.sh - the stateful rex CLI fixture shared by the Rex
# adapter unit suite and the remote second-mate suites.
#
# write_rex_fake_cli <bin-path> <d-line> emits the fake body below; callers
# pick whether the fake's state directory comes from the FM_REX_FAKE_DIR
# environment (unit tests, where each rex_env call exports it) or is baked into
# the script (a fake remote host, whose entrypoint-composed PATH carries no
# fixture variable). make_rex_fake <dir> is the unit-test shape; a remote
# fixture installs the baked shape on the remote code root's bin directory.
#
# Every invocation is logged as one space-joined line to <dir>/fake/log.
# Marker files under <dir>/fake steer failure modes: `unreachable` (every
# call exits 4), `down` (a stopped server: --autostart=false reads exit 4, any
# other call starts a fresh exit-empty server with no sessions, as Rex's
# automatic start does), `ls-fail`, `close-noop`
# (a close that leaves the block alive), and `do-fail` (`do` exits 3 before
# subscribing). Per-block canned reads live in fake/process/<uuid>.json,
# fake/status/<uuid>.json, fake/capture/<uuid>.txt and fake/capture/<uuid>.vt.
# `do` stands in for the bounded event reader: it prints "@subscribed", then
# replays fake/events (a `sleep N` line pauses), and exits 0.
#
# Remote-readiness and remote-route coverage adds four controls on top:
#   fake/endpoint    - the endpoint whoami reports (default unix:///fake/rex.sock)
#   fake/exit-empty  - the exit_empty flag whoami reports (default false)
#   fake/client-api  - the revision `rex version` reports (default 5)
#   fake/server-api  - the api_revision server.status reports (default 5)
# `server stop` marks the server down and `server start` brings it back as a
# persistent server (exit-empty cleared). This fixture models missing-session
# recovery by discarding sessions on restart, not Rex's same-endpoint session
# restoration. A fake dir carrying `agent-on-send` models a registered agent:
# a `send` into a block makes that block's `process`
# read report the harness named by fake/harness as the foreground program,
# which is how a fixture remote host reads a launched mate as alive.

# write_rex_fake_cli <bin-path> <D-assignment-line>
write_rex_fake_cli() {
  local bin=$1 dline=$2
  mkdir -p "$(dirname "$bin")"
  cat > "$bin" <<EOF
#!/usr/bin/env bash
$dline
EOF
  cat >> "$bin" <<'SH'
S="$D/state.json"
[ -f "$S" ] || printf '{"sessions":[]}' >"$S"
{ printf 'rex'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >>"$D/log"
autostart=1
exitempty=
while [ $# -gt 0 ]; do
  case "$1" in
    --autostart=false) autostart=0; shift ;;
    --exit-empty) exitempty=1; shift ;;
    -S) shift 2 ;;
    --*) shift ;;
    *) break ;;
  esac
done
# Client-side verbs and the server's own lifecycle do not consult the running
# server: `version` is an offline read, `server start|run` creates the
# answering state, and `server stop` only succeeds against a running server.
case "${1:-}" in
  version)
    printf 'rex 0.0.1-fake\napi: revision %s\n' "$(cat "$D/client-api" 2>/dev/null || printf '%s' "${FM_REX_FAKE_API:-5}")"
    exit 0 ;;
  server)
    [ ! -f "$D/unreachable" ] || { echo "error: could not connect to the rex server" >&2; exit 4; }
    shift
    case "${1:-}" in
      start)
        [ ! -f "$D/down" ] || printf '{"sessions":[]}' >"$S"
        rm -f "$D/down"; printf 'false\n' > "$D/exit-empty" ;;
      run)
        [ ! -f "$D/down" ] || printf '{"sessions":[]}' >"$S"
        rm -f "$D/down"
        if [ -n "$exitempty" ]; then printf 'true\n' > "$D/exit-empty"; fi ;;
      stop)
        [ ! -f "$D/down" ] || { echo "error: rex server is not running" >&2; exit 1; }
        touch "$D/down" ;;
      *) exit 2 ;;
    esac
    exit 0 ;;
esac
if [ -f "$D/unreachable" ]; then echo "error: could not connect to the rex server" >&2; exit 4; fi
if [ -f "$D/down" ]; then
  if [ "$autostart" = 0 ]; then echo "error: could not connect to the rex server" >&2; exit 4; fi
  rm -f "$D/down"
  printf '{"sessions":[]}' >"$S"
  printf 'true\n' > "$D/exit-empty"
fi
newid() {
  local n
  n=$(( $(cat "$D/.n" 2>/dev/null || echo 0) + 1 ))
  echo "$n" >"$D/.n"
  printf '%s:%08x-0000-7000-8000-%012x' "$1" "$n" "$n"
}
save() { jq "$@" "$S" >"$S.tmp" && mv "$S.tmp" "$S"; }
notfound() { echo "error: $1 not found" >&2; exit 3; }
has_session() { jq -e --arg s "$1" 'any(.sessions[]; .session_id == $s)' "$S" >/dev/null; }
has_block() {
  jq -e --arg s "$1" --arg b "$2" \
    'any(.sessions[] | select(.session_id == $s) | .windows[].blocks[]; .block_id == $b)' "$S" >/dev/null
}
cmd=${1:-}; shift
sub=
case "$cmd" in window|block|api) sub=${1:-}; shift ;; esac
sid=; bid=; fmt=text; wlabel=; pos=()
while [ $# -gt 0 ]; do
  case "$1" in
    -s) sid=$2; shift 2 ;;
    -b) bid=$2; shift 2 ;;
    --format=*) fmt=${1#--format=}; shift ;;
    --window) wlabel=$2; shift 2 ;;
    --cwd) shift 2 ;;
    --) shift; pos+=("$@"); break ;;
    --*) shift ;;
    *) pos+=("$1"); shift ;;
  esac
done
p0=${pos[0]:-}; p1=${pos[1]:-}
case "$cmd:$sub" in
  whoami:)
    [ ! -f "$D/whoami-fail" ] || exit 1
    if [ -f "$D/whoami.json" ]; then cat "$D/whoami.json"; exit 0; fi
    printf '{"endpoint":"%s","principal":"peer","exit_empty":%s}\n' \
      "$(cat "$D/endpoint" 2>/dev/null || printf '%s' "${FM_REX_FAKE_ENDPOINT:-unix:///fake/rex.sock}")" \
      "$(cat "$D/exit-empty" 2>/dev/null || printf 'false')" ;;
  ls:)
    [ ! -f "$D/ls-fail" ] || exit 1
    jq -c '{sessions: [.sessions[] | {session_id, label}]}' "$S" ;;
  api:call)
    case "$p0" in
      server.status) printf '{"api_revision":%s}\n' "$(cat "$D/server-api" 2>/dev/null || printf '%s' "${FM_REX_FAKE_SERVER_API:-5}")" ;;
      session.view)
        has_session "$sid" || notfound "session"
        jq -c --arg s "$sid" '.sessions[] | select(.session_id == $s)
          | if ((.windows // []) | length) == 0 then {session_id, label}
            else {session_id, label, windows: [.windows[] | {window_id, label,
              layers: [{blocks: [.blocks[] | {block_id, label}]}]}]} end' "$S" ;;
      *) exit 2 ;;
    esac ;;
  new:)
    s=$(newid session); w=$(newid window); b=$(newid block)
    save --arg s "$s" --arg w "$w" --arg b "$b" --arg l "$p0" --arg wl "$wlabel" \
      '.sessions += [{session_id: $s, label: $l, windows: [{window_id: $w, label: $wl,
        blocks: [{block_id: $b, label: "shell", columns: 80, rows: 24}]}]}]'
    printf '{"session_id":"%s","initial_windows":[{"window_id":"%s","block_ids":["%s"]}]}\n' "$s" "$w" "$b" ;;
  window:new)
    has_session "$sid" || notfound "session"
    w=$(newid window); b=$(newid block)
    save --arg s "$sid" --arg w "$w" --arg b "$b" --arg l "$p0" \
      '(.sessions[] | select(.session_id == $s) | .windows) += [{window_id: $w, label: $l,
        blocks: [{block_id: $b, label: "shell", columns: 80, rows: 24}]}]'
    printf '{"window_id":"%s","block_ids":["%s"]}\n' "$w" "$b" ;;
  block:rename)
    has_block "$sid" "$p0" || notfound "block"
    save --arg s "$sid" --arg b "$p0" --arg l "$p1" \
      '(.sessions[] | select(.session_id == $s) | .windows[].blocks[] | select(.block_id == $b) | .label) = $l' ;;
  block:close)
    has_block "$sid" "$p0" || notfound "block"
    [ ! -f "$D/close-noop" ] || exit 0
    save --arg s "$sid" --arg b "$p0" \
      '(.sessions[] | select(.session_id == $s) | .windows) |= ([.[] | .blocks |= map(select(.block_id != $b))]
        | map(select(.blocks | length > 0)))' ;;
  block:call)
    has_block "$sid" "$bid" || notfound "block"
    u=${bid#block:}
    case "$p0" in
      size)
        jq -c --arg s "$sid" --arg b "$bid" '.sessions[] | select(.session_id == $s) | .windows[].blocks[]
          | select(.block_id == $b) | {columns, rows, owner: null}' "$S" ;;
      resize)
        save --arg s "$sid" --arg b "$bid" --argjson r "$p1" \
          '(.sessions[] | select(.session_id == $s) | .windows[].blocks[] | select(.block_id == $b))
            |= (.columns = $r.columns | .rows = $r.rows)' ;;
      process)
        if [ -f "$D/process/$u.json" ]; then cat "$D/process/$u.json"
        elif [ -f "$D/agent-on-send" ] && [ -f "$D/agent-blocks" ] \
          && grep -qxF "$bid" "$D/agent-blocks" 2>/dev/null; then
          h=$(cat "$D/harness" 2>/dev/null || printf 'codex')
          printf '{"foreground":{"pid":4242,"name":"%s","path":"/usr/bin/%s","argv0":"%s","cwd":"/tmp"},"ancestors":[{"pid":99,"name":"bash"}],"last_exit":null}\n' "$h" "$h" "$h"
        else
          printf '{"foreground":{"pid":%s,"name":"zsh","path":"/bin/zsh","argv0":"-zsh","cwd":"/tmp"},"ancestors":[],"last_exit":null}\n' "${FM_REX_FAKE_DEAD_PID:-99999999}"
        fi ;;
      program_status)
        if [ -f "$D/status/$u.json" ]; then cat "$D/status/$u.json"; else printf '{"records":[]}\n'; fi ;;
      format)
        # The styled grid without the newline `capture` adds when the grid
        # does not already end in one, then the cursor from fake/cursor/<uuid>
        # ("<row>;<col>") when extra_cursor is asked for.
        content=$(cat "$D/capture/$u.vt" 2>/dev/null && printf x); content=${content%x}
        case "$content" in *$'\r\n') ;; *$'\n') content=${content%$'\n'} ;; esac
        case "$p1" in
          *extra_cursor*) [ ! -f "$D/cursor/$u" ] || content="$content"$'\033['"$(cat "$D/cursor/$u")H" ;;
        esac
        printf '%s' "$content" | jq -Rs '{content: .}' ;;
      *) exit 2 ;;
    esac ;;
  capture:)
    has_block "$sid" "$bid" || notfound "block"
    u=${bid#block:}
    if [ "$fmt" = vt ]; then cat "$D/capture/$u.vt" 2>/dev/null; else cat "$D/capture/$u.txt" 2>/dev/null; fi ;;
  send:)
    has_block "$sid" "$bid" || notfound "block"
    [ -n "$p0" ] || exit 2
    printf '%s\n' "$p0" >>"$D/sent"
    [ ! -f "$D/agent-on-send" ] || printf '%s\n' "$bid" >> "$D/agent-blocks" ;;
  send-key:)
    has_block "$sid" "$bid" || notfound "block"
    case "$p0" in enter|escape|tab|ctrl+c|ctrl+u) ;; *) exit 2 ;; esac
    printf '%s\n' "$p0" >>"$D/keys" ;;
  do:)
    has_session "$sid" || notfound "session"
    [ ! -f "$D/do-fail" ] || exit 3
    echo "@subscribed"
    if [ -f "$D/events" ]; then
      while IFS= read -r line; do
        case "$line" in
          "sleep "*) sleep "${line#sleep }" ;;
          *) printf '%s\n' "$line" ;;
        esac
      done <"$D/events"
    fi ;;
  kill:)
    has_session "$p0" || notfound "session"
    save --arg s "$p0" '.sessions |= map(select(.session_id != $s))' ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$bin"
}

# make_rex_fake <dir>: the unit-test shape - the fake resolves its state dir
# from FM_REX_FAKE_DIR, which rex_env exports per call.
make_rex_fake() {
  local dir=$1
  mkdir -p "$dir/bin" "$dir/fake/process" "$dir/fake/status" "$dir/fake/capture" "$dir/fake/cursor" "$dir/home/state"
  # shellcheck disable=SC2016 # Expanded by the generated fake at runtime.
  write_rex_fake_cli "$dir/bin/rex" 'D="${FM_REX_FAKE_DIR:?}"'
}

# install_remote_rex_fixture <remote-root> <fake-dir> <endpoint> [harness]:
# the baked shape for a fake remote host - a rex CLI on the remote code root's
# own bin directory, with a private state dir that reports <endpoint> and
# models a registered agent once text is sent into a block.
install_remote_rex_fixture() {
  local remote_root=$1 fake_dir=$2 endpoint=$3 harness=${4:-codex}
  mkdir -p "$remote_root/bin" "$fake_dir/process" "$fake_dir/status" "$fake_dir/capture" "$fake_dir/cursor"
  write_rex_fake_cli "$remote_root/bin/rex" "D='$fake_dir'"
  printf '%s\n' "$endpoint" > "$fake_dir/endpoint"
  printf '%s\n' "$harness" > "$fake_dir/harness"
  : > "$fake_dir/agent-on-send"
  : > "$fake_dir/sent"
}

# fake_rex: drive the env-shaped fake directly (test setup and server-state
# reads).
fake_rex() {  # <dir> <rex-args...>
  local dir=$1
  shift
  FM_REX_FAKE_DIR="$dir/fake" "$dir/bin/rex" "$@"
}

# install_rex_fake_state <fake-dir> <endpoint>: write the control files the
# shared fake reads (endpoint, exit-empty, client-api, server-api) plus the
# per-block canned dirs, for harnesses that install the CLI themselves - the
# remote-doctor fixture bakes D= but wants the same file-driven defaults.
install_rex_fake_state() {
  local fake_dir=$1 endpoint=$2
  mkdir -p "$fake_dir/process" "$fake_dir/status" "$fake_dir/capture" "$fake_dir/cursor"
  printf '%s\n' "$endpoint" > "$fake_dir/endpoint"
  printf 'false\n' > "$fake_dir/exit-empty"
  printf '8\n' > "$fake_dir/client-api"
  printf '8\n' > "$fake_dir/server-api"
  : > "$fake_dir/log"
}
