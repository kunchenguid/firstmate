#!/usr/bin/env bash
# tests/fm-backend-herdr-core.test.sh - fake-hc-CLI unit tests for the
# herdr-core session-provider adapter (bin/backends/herdr-core.sh,
# docs/herdr-core-backend.md) and its dispatcher wiring (bin/fm-backend.sh).
# Mirrors tests/fm-backend-tern.test.sh's convention but the fake is STATEFUL
# rather than response-numbered: a small terminal registry in
# $FM_HC_FAKE_STATE/terms/<addr>.json models `hc run/get/ls/read/send/keys/
# kill/rm/label`, because the adapter's pending-buffer, dup-guard and
# kill-then-recheck semantics only have honest answers against state that
# survives across calls. The real-binary smoke test lives in
# tests/fm-backend-herdr-core-smoke.test.sh, gated on an installed hc.
#
# Fixture contract: every fake call appends one line to $FM_HC_LOG -
# `hc`, then the pinned HC_SESSION/HC_SOCKET env values, then argv, all
# separated by the unit separator 0x1f - so tests assert BOTH the command
# shape and that the adapter pinned (never inherited) the session domain.
# shellcheck disable=SC2016 # File-wide: run_hc/run_dispatch pass single-quoted snippets to `bash -c`, where the CHILD shell expands $1..$9 and $0 from the arguments that follow.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr-core adapter)"; exit 0; }

# This suite may itself run inside a core terminal or a herdr pane; ambient
# markers must never leak into the assertions below.
unset TMUX HERDR_ENV CMUX_WORKSPACE_ID TERM_PROGRAM TERN_PANE \
  HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE HC_SESSION HC_SOCKET \
  FM_HC_BIN FM_HC_SESSION FM_HC_SOCKET

TMP_ROOT=$(fm_test_tmproot fm-backend-herdr-core-tests)

SES=fm-hclab-unit
SOCK=/tmp/fm-hc-fake-unit.sock
US=$'\x1f'

make_hc_fakebin() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb" "$dir/state/terms" "$dir/home-state"
  cat > "$fb/hc" <<'SH'
#!/usr/bin/env bash
set -u
LOG=${FM_HC_LOG:?}
FSTATE=${FM_HC_FAKE_STATE:?}
{
  printf 'hc'
  printf '\x1f%s' "HC_SESSION=${HC_SESSION-}" "HC_SOCKET=${HC_SOCKET-}"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"

if [ "${1:-}" = "--version" ]; then
  printf 'hc %s\n' "${FM_HC_FAKE_VERSION:-0.1.14}"
  exit 0
fi

TERMS="$FSTATE/terms"
mkdir -p "$TERMS"

hcerr() {  # <rc> <kind> <message>
  printf '{"error":{"kind":"%s","message":"%s"}}\n' "$2" "$3"
  exit "$1"
}

term_file() { printf '%s/terms/%s.json' "$FSTATE" "$1"; }

next_addr() {
  local n
  n=$(( $(cat "$FSTATE/next" 2>/dev/null || echo 0) + 1 ))
  printf '%s' "$n" > "$FSTATE/next"
  printf 't%s' "$n"
}

term_screen_append() {  # <addr> <text>
  local f t
  f=$(term_file "$1")
  t=$(jq --arg x "$2" '.screen = ((.screen // "") + $x)' "$f" 2>/dev/null) || return 1
  printf '%s\n' "$t" > "$f"
}

cmd=${1:-}
[ $# -gt 0 ] && shift || true

case "$cmd" in
  connect)
    # Line JSON-RPC: one response per request line. The fake server speaks
    # generation $FM_HC_FAKE_GENERATION; a hello for a different generation is
    # answered with unsupported_generation, as the real core does.
    want=${FM_HC_FAKE_GENERATION:-1}
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      id=$(printf '%s' "$line" | jq -r '.id // 0' 2>/dev/null || echo 0)
      gen=$(printf '%s' "$line" | jq -r '.params.generation // empty' 2>/dev/null || true)
      if [ "$gen" = "$want" ]; then
        printf '{"jsonrpc":"2.0","id":%s,"result":{"generation":%s,"version":"%s","methods":["hello","terminal.send"],"features":{}}}\n' \
          "$id" "$want" "${FM_HC_FAKE_VERSION:-0.1.14}"
      else
        printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32602,"message":"unsupported_generation","data":{"generation":%s}}}\n' \
          "$id" "$want"
      fi
    done
    ;;
  server)
    case "${1:-}" in
      start) printf '{"started":true,"pid":4242,"session":"%s"}\n' "${HC_SESSION-}" ;;
      status) printf '{"pid":4242,"session":"%s","socket":"%s","running":true}\n' "${HC_SESSION-}" "${HC_SOCKET-}" ;;
      stop) printf '{"stopped":true}\n' ;;
      restart) printf '{"restarted":true,"pid":4243}\n' ;;
      *) hcerr 6 invalid_params "unknown server subcommand" ;;
    esac
    ;;
  run)
    cwd=$PWD name='' labels='{}' argv='["-zsh"]'
    while [ $# -gt 0 ]; do
      case "$1" in
        --cwd) cwd=$2; shift 2 ;;
        --name) name=$2; shift 2 ;;
        --label)
          kv=$2
          labels=$(printf '%s' "$labels" | jq --arg k "${kv%%=*}" --arg v "${kv#*=}" '. + {($k): $v}')
          shift 2 ;;
        --json|--bg|--no-parent|--no-notify|--keep) shift ;;
        --) shift; argv=$(jq -n '$ARGS.positional' --args "$@"); break ;;
        -*) shift ;;
        *) argv=$(jq -n '$ARGS.positional' --args "$@"); break ;;
      esac
    done
    addr=$(next_addr)
    agent=$(printf '%s' "$argv" | jq -r '.[0] | sub("^-";"") | sub(".*/";"")')
    rec=$(jq -nc --arg a "$addr" --arg cwd "$cwd" --arg name "$name" --arg agent "$agent" \
      --argjson labels "$labels" --argjson argv "$argv" \
      '{address:$a,agent:$agent,argv:$argv,cwd:$cwd,foreground:null,labels:$labels,name:$name,pid:4242,state:"live",status:null,reported:false,reason:null,turn:0,dimensions:{cols:80,rows:24},screen:""}')
    printf '%s\n' "$rec" > "$(term_file "$addr")"
    printf '%s\n' "$rec"
    ;;
  ls)
    all=0 labels_args=''
    while [ $# -gt 0 ]; do
      case "$1" in
        --all) all=1; shift ;;
        --json) shift ;;
        --label) labels_args="$labels_args${labels_args:+ }$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    {
      printf '{"hidden_finished":0,"terminals":['
      first=1
      for f in "$TERMS"/*.json; do
        [ -e "$f" ] || continue
        state=$(jq -r '.state' "$f")
        if [ "$all" != 1 ] && [ "$state" != live ]; then continue; fi
        match=1
        for kv in $labels_args; do
          v=$(jq -r --arg k "${kv%%=*}" '.labels[$k] // ""' "$f")
          [ "$v" = "${kv#*=}" ] || { match=0; break; }
        done
        [ "$match" = 1 ] || continue
        [ "$first" = 1 ] || printf ','
        first=0
        jq -c '{address,agent,cwd,name,state,turn}' "$f"
      done
      printf ']}\n'
    }
    ;;
  get)
    t=${1:-}
    f=$(term_file "$t")
    [ -f "$f" ] || hcerr 3 not_found "no terminal: $t"
    cat "$f"
    ;;
  read)
    t=${1:-}; shift
    lines=''
    while [ $# -gt 0 ]; do
      case "$1" in
        --lines) lines=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    f=$(term_file "$t")
    [ -f "$f" ] || hcerr 3 not_found "no terminal: $t"
    state=$(jq -r '.state' "$f")
    [ "$state" = finished ] && hcerr 11 finished "terminal $t is finished"
    screen=$(jq -r '.screen // ""' "$f")
    if [ -n "$lines" ]; then
      text=$(printf '%s\n' "$screen" | tail -n "$lines")
      jq -nc --arg t "$text" '{complete:true,how:"history",text:$t}'
    else
      jq -nc --arg t "$screen" '{complete:true,how:"screen",text:$t}'
    fi
    ;;
  send)
    t=${1:-}; shift
    wait=0 timeout='' if_want=''
    while [ $# -gt 0 ]; do
      case "$1" in
        --wait) wait=1; shift ;;
        --timeout) timeout=$2; shift 2 ;;
        --if) if_want=$2; shift 2 ;;
        --json|--no-notify|--no-parent) shift ;;
        --) shift; break ;;
        *) break ;;
      esac
    done
    text=${1:-}
    f=$(term_file "$t")
    [ -f "$f" ] || hcerr 3 not_found "no terminal: $t"
    state=$(jq -r '.state' "$f")
    [ "$state" = finished ] && hcerr 11 finished "terminal $t is finished"
    status=$(jq -r '.status // ""' "$f")
    if [ -n "$if_want" ] && [ "$status" != "$if_want" ]; then
      hcerr 10 status_mismatch "terminal $t is $status, not $if_want"
    fi
    if [ "$status" = blocked ] && [ "${FM_HC_FAKE_SEND_UNBLOCK:-}" != 1 ]; then
      hcerr 9 blocked "terminal $t is blocked waiting on input"
    fi
    term_screen_append "$t" "$text
" || hcerr 5 unavailable "screen update failed"
    if [ "$wait" = 1 ]; then
      printf '{"started":%s,"wait":{"status":"%s","ended":false,"reason":"timeout","timed_out":true}}\n' \
        "${FM_HC_FAKE_STARTED:-null}" "${FM_HC_FAKE_WAIT_STATUS:-idle}"
    else
      printf '{"sent":true}\n'
    fi
    ;;
  keys)
    t=${1:-}; shift
    [ "${1:-}" = "--" ] && shift
    f=$(term_file "$t")
    [ -f "$f" ] || hcerr 3 not_found "no terminal: $t"
    state=$(jq -r '.state' "$f")
    [ "$state" = finished ] && hcerr 11 finished "terminal $t is finished"
    for k in "$@"; do
      case "$k" in
        enter) term_screen_append "$t" "
" ;;
        space) term_screen_append "$t" ' ' ;;
        backspace)
          scr=$(jq -r '.screen // ""' "$f")
          scr=${scr%?}
          jq --arg s "$scr" '.screen = $s' "$f" > "$f.tmp" && mv "$f.tmp" "$f" ;;
        ctrl+u)
          scr=$(jq -r '.screen // ""' "$f")
          scr=${scr%$'\n'*}
          case "$scr" in *$'\n'*) ;; *) scr='' ;; esac
          jq --arg s "$scr" '.screen = $s' "$f" > "$f.tmp" && mv "$f.tmp" "$f" ;;
        ctrl+c) term_screen_append "$t" '^C
' ;;
        ?) term_screen_append "$t" "$k" ;;
        *) : ;;
      esac
    done
    printf '{"sent":true}\n'
    ;;
  interrupt)
    t=${1:-}
    f=$(term_file "$t")
    [ -f "$f" ] || hcerr 3 not_found "no terminal: $t"
    term_screen_append "$t" '^C'
    printf '{"key":"ctrl+c","outcome":"sent"}\n'
    ;;
  kill)
    t=${1:-}
    f=$(term_file "$t")
    [ -f "$f" ] || hcerr 3 not_found "no terminal: $t"
    jq '.state = "finished" | .reason = "killed" | .exit_code = 1' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    cat "$f"
    ;;
  rm)
    t=${1:-}
    f=$(term_file "$t")
    [ -f "$f" ] || hcerr 3 not_found "no terminal: $t"
    state=$(jq -r '.state' "$f")
    [ "$state" = live ] && hcerr 6 invalid_params "terminal $t is still live"
    rm -f "$f"
    printf '{"removed":"%s"}\n' "$t"
    ;;
  label)
    t=${1:-}; shift
    f=$(term_file "$t")
    [ -f "$f" ] || hcerr 3 not_found "no terminal: $t"
    for kv in "$@"; do
      jq --arg k "${kv%%=*}" --arg v "${kv#*=}" '.labels[$k] = $v' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    done
    cat "$f"
    ;;
  events) : ;;
  schema) printf '{}\n' ;;
  *) hcerr 6 invalid_params "unknown command: $cmd" ;;
esac
SH
  chmod +x "$fb/hc"
  printf '%s\n' "$fb"
}

new_case() {  # <name> -> echoes dir with fakebin, fake state, empty log
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state/terms" "$dir/home-state"
  : > "$dir/log"
  make_hc_fakebin "$dir" >/dev/null
  printf '%s\n' "$dir"
}

# mkterm <dir> <addr> [jq-filter...]: seed a terminal record directly - the
# states `hc run` cannot produce (finished, reported status, foreground).
mkterm() {  # <dir> <addr> [jq filter]
  local dir=$1 addr=$2 filter=${3:-.}
  mkdir -p "$dir/state/terms"
  jq -nc --arg a "$addr" \
    '{address:$a,agent:"zsh",argv:["-zsh"],cwd:"/tmp",foreground:null,labels:{},name:("name-"+$a),pid:4242,state:"live",status:null,reported:false,reason:null,turn:0,dimensions:{cols:80,rows:24},screen:""} | '"$filter" \
    > "$dir/state/terms/$addr.json"
}

# run_hc <dir> <bash-snippet> [args...]: run a snippet against the adapter with
# the fake hc on PATH via FM_HC_BIN. $0 is the repo root, "$@" are the args.
run_hc() {
  local dir=$1 snippet=$2
  shift 2
  env -i PATH="$dir/fakebin:$PATH" HOME="$dir/home" \
    FM_HC_BIN="$dir/fakebin/hc" FM_HC_LOG="$dir/log" FM_HC_FAKE_STATE="$dir/state" \
    FM_HC_SESSION="$SES" FM_HC_SOCKET="$SOCK" \
    FM_STATE_OVERRIDE="$dir/home-state" FM_HOME="$dir/home" \
    FM_HC_FAKE_VERSION="${FM_HC_FAKE_VERSION:-0.1.14}" \
    FM_HC_FAKE_GENERATION="${FM_HC_FAKE_GENERATION:-1}" \
    FM_HC_FAKE_STARTED="${FM_HC_FAKE_STARTED:-null}" \
    FM_HC_FAKE_WAIT_STATUS="${FM_HC_FAKE_WAIT_STATUS:-idle}" \
    bash -c ". \"\$0/bin/backends/herdr-core.sh\"; $snippet" "$ROOT" "$@"
}

# run_dispatch <dir> <bash-snippet> [args...]: same but sourced through the
# dispatcher, so fm_backend_* functions are exercised end to end.
run_dispatch() {
  local dir=$1 snippet=$2
  shift 2
  env -i PATH="$dir/fakebin:$PATH" HOME="$dir/home" \
    FM_HC_BIN="$dir/fakebin/hc" FM_HC_LOG="$dir/log" FM_HC_FAKE_STATE="$dir/state" \
    FM_HC_SESSION="$SES" FM_HC_SOCKET="$SOCK" \
    FM_STATE_OVERRIDE="$dir/home-state" FM_HOME="$dir/home" \
    FM_HC_FAKE_VERSION="${FM_HC_FAKE_VERSION:-0.1.14}" \
    FM_HC_FAKE_GENERATION="${FM_HC_FAKE_GENERATION:-1}" \
    FM_HC_FAKE_STARTED="${FM_HC_FAKE_STARTED:-null}" \
    FM_HC_FAKE_WAIT_STATUS="${FM_HC_FAKE_WAIT_STATUS:-idle}" \
    bash -c ". \"\$0/bin/fm-backend.sh\"; $snippet" "$ROOT" "$@"
}

# log_has <dir> <pattern>: fixed-string grep over the 0x1f-framed call log.
log_has() { grep -Fq -e "$2" "$1/log" 2>/dev/null; }
log_count() { local c; c=$(grep -Fc -e "$2" "$1/log" 2>/dev/null || true); printf '%s\n' "${c:-0}"; }

# --- 1. binary + version gate ------------------------------------------------

test_version_gate() {
  local dir; dir=$(new_case vgate)
  run_hc "$dir" 'fm_backend_herdr_core_version_check' || fail "version check should accept hc 0.1.14"
  FM_HC_FAKE_VERSION=0.1.9 run_hc "$dir" 'fm_backend_herdr_core_version_check' 2>/dev/null \
    && fail "version check should refuse hc 0.1.9 (below the verified floor 0.1.14)"
  FM_HC_FAKE_VERSION=9.9.9 run_hc "$dir" 'fm_backend_herdr_core_version_check' \
    || fail "version check is a floor, not a pin: hc 9.9.9 should be accepted"
  # A misnamed binary: version output that is not `hc x.y.z`.
  printf '#!/usr/bin/env bash\nprintf "not-hc 1.0\\n"\n' > "$dir/fakebin/hc2"
  chmod +x "$dir/fakebin/hc2"
  env -i PATH="$dir/fakebin:$PATH" HOME="$dir/home" \
    FM_HC_BIN="$dir/fakebin/hc2" FM_HC_LOG="$dir/log" FM_HC_FAKE_STATE="$dir/state" \
    FM_HC_SESSION="$SES" FM_HC_SOCKET="$SOCK" FM_STATE_OVERRIDE="$dir/home-state" FM_HOME="$dir/home" \
    bash -c ". \"$ROOT/bin/backends/herdr-core.sh\"; fm_backend_herdr_core_version_check" 2>/dev/null \
    && fail "version check should refuse a binary that does not self-identify as hc"
  # Missing binary: FM_HC_BIN pointing at nothing executable.
  env -i PATH="$dir/fakebin:$PATH" HOME="$dir/home" \
    FM_HC_BIN="$dir/fakebin/nonexistent" FM_HC_LOG="$dir/log" FM_HC_FAKE_STATE="$dir/state" \
    FM_HC_SESSION="$SES" FM_HC_SOCKET="$SOCK" FM_STATE_OVERRIDE="$dir/home-state" FM_HOME="$dir/home" \
    bash -c ". \"$ROOT/bin/backends/herdr-core.sh\"; fm_backend_herdr_core_tool_check" 2>/dev/null \
    && fail "tool check should refuse a non-executable FM_HC_BIN"
  pass "version gate accepts hc 0.1.14, refuses hc 0.1.9 and a non-hc binary"
}

# --- 2. session name rules ----------------------------------------------------

test_session_rules() {
  local dir; dir=$(new_case sesrules)
  # `default` is refused even as an explicit override - it is the user's own.
  env -i PATH="$dir/fakebin:$PATH" HOME="$dir/home" \
    FM_HC_BIN="$dir/fakebin/hc" FM_HC_LOG="$dir/log" FM_HC_FAKE_STATE="$dir/state" \
    FM_HC_SESSION=default FM_HC_SOCKET="$SOCK" FM_STATE_OVERRIDE="$dir/home-state" FM_HOME="$dir/home" \
    bash -c ". \"$ROOT/bin/backends/herdr-core.sh\"; fm_backend_herdr_core_container_ensure" 2>/dev/null \
    && fail "container_ensure should refuse the 'default' session"
  # Unsafe names refuse: spaces, colons, slashes.
  for bad in 'has space' 'has:colon' 'has/slash'; do
    env -i PATH="$dir/fakebin:$PATH" HOME="$dir/home" \
      FM_HC_BIN="$dir/fakebin/hc" FM_HC_LOG="$dir/log" FM_HC_FAKE_STATE="$dir/state" \
      FM_HC_SESSION="$bad" FM_HC_SOCKET="$SOCK" FM_STATE_OVERRIDE="$dir/home-state" FM_HOME="$dir/home" \
      bash -c ". \"$ROOT/bin/backends/herdr-core.sh\"; fm_backend_herdr_core_valid_session \"\$1\"" "$ROOT" "$bad" 2>/dev/null \
      && fail "valid_session should refuse '$bad'"
  done
  # The derived name (no FM_HC_SESSION) must carry the fm- prefix.
  out=$(env -i PATH="$dir/fakebin:$PATH" HOME="$dir/home" \
    FM_HC_BIN="$dir/fakebin/hc" FM_HC_LOG="$dir/log" FM_HC_FAKE_STATE="$dir/state" \
    FM_HC_SOCKET="$SOCK" FM_STATE_OVERRIDE="$dir/home-state" FM_HOME="$dir/home" \
    bash -c ". \"$ROOT/bin/backends/herdr-core.sh\"; fm_backend_herdr_core_session_name")
  case "$out" in fm-*) : ;; *) fail "derived session name should carry fm- prefix, got '$out'" ;; esac
  pass "session rules: default and unsafe names refused; derived name is fm-<hometag>"
}

# --- 3. target parsing --------------------------------------------------------

test_parse_target() {
  local dir; dir=$(new_case parse)
  run_hc "$dir" 'fm_backend_herdr_core_parse_target "fm-hclab-unit:t12"' \
    || fail "parse_target should accept <session>:<tN>"
  for bad in 'fm-hclab-unit:machine/t7' 'no-colon' 'a:b:c' 'fm-hclab-unit:' ':t1' 'fm-hclab-unit:t1:extra'; do
    run_hc "$dir" 'fm_backend_herdr_core_parse_target "$1"' "$bad" 2>/dev/null \
      && fail "parse_target should refuse '$bad'"
  done
  pass "parse_target accepts <session>:<t-alnum> and refuses remote machine/t7, colons, and empty halves"
}

# --- 4. generation gate --------------------------------------------------------

test_generation_gate() {
  local dir; dir=$(new_case ggate)
  out=$(run_hc "$dir" 'fm_backend_herdr_core_container_ensure') || fail "container_ensure failed on a generation-1 fake"
  [ "$out" = "$SES" ] || fail "container_ensure should echo the session name, got '$out'"
  log_has "$dir" "server${US}start" || fail "container_ensure should issue hc server start"
  FM_HC_FAKE_GENERATION=2 run_hc "$dir" 'fm_backend_herdr_core_container_ensure' 2>/dev/null \
    && fail "container_ensure should refuse a generation-2 core"
  pass "generation gate: hello handshake gates on protocol generation 1"
}

# --- 5. create_task labels + dup guard ------------------------------------------

test_create_task_labels() {
  local dir; dir=$(new_case mk)
  addr=$(run_hc "$dir" 'fm_backend_herdr_core_create_task fm-unitask1 /tmp/proj-one') \
    || fail "create_task failed: $addr"
  case "$addr" in t[0-9]*) : ;; *) fail "create_task should return a t<alnum> address, got '$addr'" ;; esac
  rec=$(cat "$dir/state/terms/$addr.json")
  [ "$(printf '%s' "$rec" | jq -r '.labels["fm.id"]')" = unitask1 ] || fail "record should carry fm.id=unitask1: $rec"
  fid_home=$(printf '%s' "$rec" | jq -r '.labels["fm.home"]')
  [ -n "$fid_home" ] || fail "record should carry fm.home: $rec"
  [ "$(printf '%s' "$rec" | jq -r '.labels["fm.project"]')" = proj-one ] || fail "record should carry fm.project=proj-one: $rec"
  [ "$(printf '%s' "$rec" | jq -r '.cwd')" = /tmp/proj-one ] || fail "record should carry cwd /tmp/proj-one"
  # Labels come through `hc run --label`; verify the call shape too.
  log_has "$dir" "run${US}--bg${US}--json${US}--cwd${US}/tmp/proj-one" \
    || fail "run call should carry --bg --json --cwd"
  log_has "$dir" "--label${US}fm.id=unitask1" || fail "run call should carry --label fm.id=unitask1"
  # A second create with the same fm.id in this session refuses.
  run_hc "$dir" 'fm_backend_herdr_core_create_task fm-unitask1 /tmp/proj-one' 2>/dev/null \
    && fail "create_task should refuse a duplicate live fm.id"
  pass "create_task labels the terminal fm.id/fm.home/fm.project and refuses a duplicate fm.id"
}

# --- 6. target_ready -----------------------------------------------------------

test_target_ready() {
  local dir; dir=$(new_case ready)
  mkterm "$dir" t5 '.labels["fm.id"]="task5"'
  run_hc "$dir" "fm_backend_herdr_core_target_ready $SES:t5 fm-task5" \
    || fail "target_ready should accept a live terminal with matching fm.id"
  run_hc "$dir" "fm_backend_herdr_core_target_ready $SES:t5 fm-other" 2>/dev/null \
    && fail "target_ready should refuse a mismatched expected label"
  run_hc "$dir" "fm_backend_herdr_core_target_ready $SES:t99 fm-task5" 2>/dev/null \
    && fail "target_ready should refuse an absent terminal"
  mkterm "$dir" t6 '.state="finished" | .labels["fm.id"]="task6"'
  run_hc "$dir" "fm_backend_herdr_core_target_ready $SES:t6 fm-task6" 2>/dev/null \
    && fail "target_ready should refuse a finished terminal"
  pass "target_ready verifies the live terminal and its fm.id label"
}

# --- 7. pending literal buffer ---------------------------------------------------

test_pending_literal() {
  local dir; dir=$(new_case pend)
  mkterm "$dir" t1 '.labels["fm.id"]="lit1"'
  run_hc "$dir" "fm_backend_herdr_core_send_literal $SES:t1 'echo \"a_b:c\"' fm-lit1" \
    || fail "send_literal failed"
  # No hc send should have run yet - the text rides the pending buffer.
  [ "$(log_count "$dir" "${US}send${US}")" = 0 ] \
    || fail "send_literal should buffer, not call hc send"
  run_hc "$dir" "fm_backend_herdr_core_send_key $SES:t1 Enter fm-lit1" \
    || fail "send_key Enter failed"
  # Exactly ONE `hc send` flushed buffer + Enter atomically past the -- delimiter.
  [ "$(log_count "$dir" "${US}send${US}")" = 1 ] \
    || fail "expected exactly one hc send after Enter, got: $(cat "$dir/log")"
  log_has "$dir" "send${US}t1${US}--${US}echo \"a_b:c\"" \
    || fail "the send should carry the buffered literal text past --: $(cat "$dir/log")"
  # The pending file is dropped after a successful flush.
  [ -f "$dir/home-state/.herdr-core-pending-${SES}__t1" ] \
    && fail "the pending buffer should be dropped after a successful flush"
  pass "pending literal: send_literal buffers, Enter flushes through one hc send past --"
}

# --- 8. ctrl+u / ctrl+c drop the buffer -------------------------------------------

test_pending_drop_on_clear() {
  local dir; dir=$(new_case drop)
  mkterm "$dir" t1 '.labels["fm.id"]="lit2"'
  run_hc "$dir" "fm_backend_herdr_core_send_literal $SES:t1 'half-typed' fm-lit2" || fail "send_literal failed"
  run_hc "$dir" "fm_backend_herdr_core_send_key $SES:t1 C-u fm-lit2" || fail "send_key C-u failed"
  log_has "$dir" "keys${US}t1${US}--${US}ctrl+u" || fail "C-u should reach hc keys as ctrl+u"
  [ "$(log_count "$dir" "${US}send${US}")" = 0 ] || fail "C-u must not flush the buffer through send"
  [ -f "$dir/home-state/.herdr-core-pending-${SES}__t1" ] \
    && fail "the pending buffer should be dropped on C-u"
  run_hc "$dir" "fm_backend_herdr_core_send_literal $SES:t1 'again' fm-lit2" || fail "second send_literal failed"
  run_hc "$dir" "fm_backend_herdr_core_send_key $SES:t1 C-c fm-lit2" || fail "send_key C-c failed"
  [ -f "$dir/home-state/.herdr-core-pending-${SES}__t1" ] \
    && fail "the pending buffer should be dropped on C-c"
  log_has "$dir" "keys${US}t1${US}--${US}ctrl+c" || fail "C-c should reach hc keys as ctrl+c"
  pass "C-u and C-c drop the pending buffer and pass through hc keys"
}

# --- 9. send_text_line + flag-looking text -----------------------------------------

test_send_text_line() {
  local dir; dir=$(new_case line)
  mkterm "$dir" t2 '.labels["fm.id"]="ln2"'
  run_hc "$dir" "fm_backend_herdr_core_send_text_line $SES:t2 'cd /tmp' fm-ln2" \
    || fail "send_text_line failed"
  log_has "$dir" "send${US}t2${US}--${US}cd /tmp" \
    || fail "send_text_line should issue one hc send past --"
  run_hc "$dir" "fm_backend_herdr_core_send_text_line $SES:t2 'echo -n --flag -- also' fm-ln2" \
    || fail "send_text_line with flag-looking text failed"
  log_has "$dir" "send${US}t2${US}--${US}echo -n --flag -- also" \
    || fail "flag-looking text must be delivered after the -- delimiter"
  pass "send_text_line delivers through one hc send, with -- protecting flag-looking text"
}

# --- 10. key normalization ---------------------------------------------------------

test_key_names() {
  local dir; dir=$(new_case keys)
  mkterm "$dir" t3 '.labels["fm.id"]="k3"'
  for pair in 'Escape:esc' 'Up:up' 'Down:down' 'C-d:ctrl+d' 'F5:f5' 'Backspace:backspace' 'Tab:tab'; do
    want=${pair#*:}; key=${pair%%:*}
    run_hc "$dir" "fm_backend_herdr_core_send_key $SES:t3 $key fm-k3" \
      || fail "send_key $key failed"
    log_has "$dir" "keys${US}t3${US}--${US}$want" \
      || fail "key $key should normalize to $want: $(cat "$dir/log")"
  done
  # A key with no pending buffer goes through keys, not send.
  run_hc "$dir" "fm_backend_herdr_core_send_key $SES:t3 Enter fm-k3" || fail "bare Enter failed"
  log_has "$dir" "keys${US}t3${US}--${US}enter" \
    || fail "Enter with no pending buffer should go through hc keys"
  pass "send_key normalizes the firstmate key vocabulary onto hc names"
}

# --- 11. capture -------------------------------------------------------------------

test_capture() {
  local dir; dir=$(new_case cap)
  mkterm "$dir" t4 '.labels["fm.id"]="cap4" | .screen="line1\nline2\nline3"'
  out=$(run_hc "$dir" "fm_backend_herdr_core_capture $SES:t4 40 fm-cap4") \
    || fail "capture failed"
  case "$out" in *line2*) : ;; *) fail "capture should return the screen text, got: $out" ;; esac
  log_has "$dir" "read${US}t4${US}--json${US}--lines${US}40" \
    || fail "capture should issue read --json --lines 40"
  out=$(run_hc "$dir" "fm_backend_herdr_core_visible_capture $SES:t4 fm-cap4") || fail "visible_capture failed"
  case "$out" in *line3*) : ;; *) fail "visible_capture should return the viewport, got: $out" ;; esac
  log_has "$dir" "read${US}t4${US}--json${US}\n" \
    || log_has "$dir" "read${US}t4${US}--json" \
    || fail "visible_capture should issue read --json"
  pass "capture and visible_capture read the terminal through hc read --json"
}

# --- 12. current_path -----------------------------------------------------------------

test_current_path() {
  local dir; dir=$(new_case cwd)
  mkterm "$dir" t7 '.labels["fm.id"]="cwd7" | .cwd="/tmp/base"'
  out=$(run_hc "$dir" "fm_backend_herdr_core_current_path $SES:t7 fm-cwd7")
  case "$out" in /tmp/base) : ;; *) fail "current_path should read the terminal cwd, got '$out'" ;; esac
  mkterm "$dir" t7 '.labels["fm.id"]="cwd7" | .cwd="/tmp/base" | .foreground={argv:["claude"],cwd:"/work/task",name:"claude",pid:55}'
  out=$(run_hc "$dir" "fm_backend_herdr_core_current_path $SES:t7 fm-cwd7")
  case "$out" in /work/task) : ;; *) fail "current_path should prefer the foreground cwd, got '$out'" ;; esac
  pass "current_path prefers the foreground process cwd, falling back to the terminal cwd"
}

# --- 13. agent_state --------------------------------------------------------------------

test_agent_state() {
  local dir; dir=$(new_case as)
  mkterm "$dir" t1 '.labels["fm.id"]="s1"'
  [ "$(run_dispatch "$dir" "fm_backend_agent_state herdr-core $SES:t1")" = dead ] \
    || fail "a shell-only terminal should classify dead"
  mkterm "$dir" t2 '.labels["fm.id"]="s2" | .foreground={argv:["claude"],cwd:"/w",name:"claude",pid:9}'
  [ "$(run_dispatch "$dir" "fm_backend_agent_state herdr-core $SES:t2")" = alive ] \
    || fail "a claude foreground should classify alive"
  mkterm "$dir" t3 '.labels["fm.id"]="s3" | .argv=["claude"] | .agent="claude"'
  [ "$(run_dispatch "$dir" "fm_backend_agent_state herdr-core $SES:t3")" = alive ] \
    || fail "a direct-run claude (no foreground) should classify alive"
  mkterm "$dir" t4 '.labels["fm.id"]="s4" | .state="finished"'
  [ "$(run_dispatch "$dir" "fm_backend_agent_state herdr-core $SES:t4")" = dead ] \
    || fail "a finished terminal should classify dead"
  [ "$(run_dispatch "$dir" "fm_backend_agent_state herdr-core $SES:t99")" = missing ] \
    || fail "an absent terminal should classify missing"
  pass "agent_state: shell->dead, agent->alive, finished->dead, absent->missing"
}

# --- 14. busy_state ------------------------------------------------------------------------

test_busy_state() {
  local dir; dir=$(new_case bs)
  # Unreported program: never busy, never idle-proven.
  mkterm "$dir" t1 '.labels["fm.id"]="b1"'
  [ "$(run_dispatch "$dir" "fm_backend_busy_state herdr-core $SES:t1")" = unknown ] \
    || fail "an unreported terminal should read unknown"
  mkterm "$dir" t2 '.labels["fm.id"]="b2" | .reported=true | .status="working" | .foreground={argv:["claude"],cwd:"/w",name:"claude",pid:9}'
  [ "$(run_dispatch "$dir" "fm_backend_busy_state herdr-core $SES:t2")" = busy ] \
    || fail "a reported working agent should read busy"
  # The stale-record guard: working over a shell-only terminal reads unknown.
  mkterm "$dir" t3 '.labels["fm.id"]="b3" | .reported=true | .status="working"'
  [ "$(run_dispatch "$dir" "fm_backend_busy_state herdr-core $SES:t3")" = unknown ] \
    || fail "a stale working record over a shell should read unknown, never busy"
  mkterm "$dir" t4 '.labels["fm.id"]="b4" | .reported=true | .status="idle"'
  [ "$(run_dispatch "$dir" "fm_backend_busy_state herdr-core $SES:t4")" = idle ] \
    || fail "a reported idle should read idle"
  mkterm "$dir" t5 '.labels["fm.id"]="b5" | .reported=true | .status="blocked"'
  [ "$(run_dispatch "$dir" "fm_backend_busy_state herdr-core $SES:t5")" = blocked ] \
    || fail "a reported blocked should read blocked"
  pass "busy_state maps the OSC 7501 status with the shell-foreground guard on busy"
}

# --- 15. send_text_submit --------------------------------------------------------------------

test_submit() {
  local dir; dir=$(new_case sub)
  mkterm "$dir" t1 '.labels["fm.id"]="u1" | .screen="% "'
  # Native confirmation: started:true proves the turn - verdict empty.
  out=$(FM_HC_FAKE_STARTED=true run_dispatch "$dir" "fm_backend_send_text_submit herdr-core $SES:t1 'do thing' 2 0.2 0 fm-u1")
  [ "$out" = empty ] || fail "started:true should confirm as empty, got '$out'"
  log_has "$dir" "send${US}t1${US}--wait${US}--timeout" \
    || fail "submit should issue send --wait --timeout"
  # Silent program: started:null falls through to the screen verdict.
  out=$(FM_HC_FAKE_STARTED=null run_dispatch "$dir" "fm_backend_send_text_submit herdr-core $SES:t1 'more' 1 0.2 0 fm-u1")
  case "$out" in empty|pending|pending-unproven|unknown) : ;; *) fail "silent submit must answer the shared verdict vocabulary, got '$out'" ;; esac
  # Blocked terminal: exit 9 is a hard stop reported unknown.
  mkterm "$dir" t2 '.labels["fm.id"]="u2" | .reported=true | .status="blocked"'
  out=$(run_dispatch "$dir" "fm_backend_send_text_submit herdr-core $SES:t2 'x' 1 0.2 0 fm-u2" 2>/dev/null)
  [ "$out" = unknown ] || fail "a blocked terminal should report unknown, got '$out'"
  # Finished terminal: send-failed.
  mkterm "$dir" t3 '.labels["fm.id"]="u3" | .state="finished"'
  out=$(run_dispatch "$dir" "fm_backend_send_text_submit herdr-core $SES:t3 'x' 1 0.2 0 fm-u3" 2>/dev/null)
  [ "$out" = send-failed ] || fail "a finished terminal should report send-failed, got '$out'"
  pass "send_text_submit: started proves empty, silent falls to screen, blocked->unknown, finished->send-failed"
}

# --- 16. kill -----------------------------------------------------------------------------------

test_kill() {
  local dir; dir=$(new_case kill)
  mkterm "$dir" t1 '.labels["fm.id"]="k1"'
  run_dispatch "$dir" "fm_backend_kill herdr-core $SES:t1 '' fm-k1" \
    || fail "kill failed on a live terminal"
  [ -f "$dir/state/terms/t1.json" ] && fail "the record should be removed after kill+rm"
  log_has "$dir" "kill${US}t1" || fail "kill should issue hc kill"
  log_has "$dir" "rm${US}t1" || fail "kill should issue hc rm after the terminal finishes"
  # Idempotent: an absent target is a success.
  run_dispatch "$dir" "fm_backend_kill herdr-core $SES:t1 '' fm-k1" \
    || fail "kill on an already-gone terminal should succeed"
  # A terminal that lost its fm.id label refuses - it may not be ours.
  mkterm "$dir" t2 '.labels={}'
  run_dispatch "$dir" "fm_backend_kill herdr-core $SES:t2 '' fm-k2" 2>/dev/null \
    && fail "kill should refuse a terminal that lost its fm.id label"
  [ -f "$dir/state/terms/t2.json" ] || fail "a refused kill must not remove the terminal"
  pass "kill closes a live terminal with kill+rm, is idempotent, and refuses a label mismatch"
}

# --- 17. list_live ---------------------------------------------------------------------------------

test_list_live() {
  local dir; dir=$(new_case ll)
  tag=$(run_hc "$dir" 'fm_backend_hometag')
  mkterm "$dir" t1 ".labels[\"fm.id\"]=\"aa\" | .labels[\"fm.home\"]=\"$tag\""
  mkterm "$dir" t2 ".labels[\"fm.id\"]=\"bb\" | .labels[\"fm.home\"]=\"otherhome\""
  mkterm "$dir" t3 ".labels[\"fm.id\"]=\"cc\" | .labels[\"fm.home\"]=\"$tag\" | .state=\"finished\""
  mkterm "$dir" t4 ".labels[\"fm.home\"]=\"$tag\""
  out=$(run_hc "$dir" 'fm_backend_herdr_core_list_live')
  case "$out" in *"$SES:t1"*"fm-aa"*) : ;; *) fail "list_live should list the labeled live terminal: $out" ;; esac
  case "$out" in *"$SES:t2"*) fail "list_live must not adopt another home's terminal: $out" ;; esac
  case "$out" in *"$SES:t3"*) fail "list_live must skip finished terminals: $out" ;; esac
  case "$out" in *"$SES:t4"*) fail "list_live must skip terminals with no fm.id: $out" ;; esac
  log_has "$dir" "ls${US}--json${US}--all${US}--label${US}fm.home=$tag" \
    || fail "list_live should enumerate via ls --all --label fm.home"
  pass "list_live discovers this home's labeled live terminals as <session>:<t> fm-<id>"
}

# --- 18. dispatcher registration --------------------------------------------------------------------

test_dispatcher() {
  local dir; dir=$(new_case disp)
  # Selection + capability tables.
  run_dispatch "$dir" 'fm_backend_validate herdr-core' || fail "fm_backend_validate should know herdr-core"
  run_dispatch "$dir" 'fm_backend_validate_spawn herdr-core' || fail "fm_backend_validate_spawn should include herdr-core"
  [ "$(run_dispatch "$dir" 'fm_backend_required_tools herdr-core')" = 'herdr-core jq treehouse' ] \
    || fail "required_tools should be 'herdr-core jq treehouse'"
  # Poll-only: no push in this stage.
  run_dispatch "$dir" 'fm_backend_has_push herdr-core' && fail "herdr-core must not report push yet"
  run_dispatch "$dir" 'fm_backend_wait_transition herdr-core s 1 d x' 2>/dev/null
  [ "$?" = 2 ] || fail "wait_transition on a non-push backend must return 2"
  # Operation arms route to the adapter.
  mkterm "$dir" t8 '.labels["fm.id"]="d8"'
  run_dispatch "$dir" "fm_backend_target_exists herdr-core $SES:t8 fm-d8" \
    || fail "fm_backend_target_exists should route to the adapter"
  run_dispatch "$dir" "fm_backend_send_key herdr-core $SES:t8 Escape fm-d8" \
    || fail "fm_backend_send_key should route"
  log_has "$dir" "keys${US}t8${US}--${US}esc" || fail "dispatched Escape should reach hc keys as esc"
  run_dispatch "$dir" "fm_backend_capture herdr-core $SES:t8 20 fm-d8" >/dev/null \
    || fail "fm_backend_capture should route"
  run_dispatch "$dir" "fm_backend_visible_capture herdr-core $SES:t8 fm-d8" >/dev/null \
    || fail "fm_backend_visible_capture should route"
  run_dispatch "$dir" "fm_backend_busy_state herdr-core $SES:t8" >/dev/null \
    || fail "fm_backend_busy_state should route"
  run_dispatch "$dir" "fm_backend_composer_state herdr-core $SES:t8 fm-d8" >/dev/null \
    || fail "fm_backend_composer_state should route"
  run_dispatch "$dir" "fm_backend_agent_state herdr-core $SES:t8" >/dev/null \
    || fail "fm_backend_agent_state should route"
  run_dispatch "$dir" "fm_backend_kill herdr-core $SES:t8 '' fm-d8" \
    || fail "fm_backend_kill should route"
  pass "dispatcher: validate/spawn/tools arms plus every operation routes to the adapter; has_push stays false"
}

# --- 19. endpoint metadata validation -----------------------------------------------------------------

test_endpoint_meta() {
  local dir; dir=$(new_case meta)
  meta="$dir/task.meta"
  cat > "$meta" <<EOF
window=$SES:t7
endpoint_task_id=mytask7
worktree=/tmp/wt
project=/tmp/proj
backend=herdr-core
herdr_core_session=$SES
herdr_core_terminal=t7
EOF
  run_dispatch "$dir" 'fm_backend_validate_task_endpoint "$1" mytask7' "$meta" \
    || fail "a well-formed herdr-core record should validate"
  # Without the task binding the record refuses (opaque ids cannot self-bind).
  sed -i '' '/^endpoint_task_id=/d' "$meta"
  run_dispatch "$dir" 'fm_backend_validate_task_endpoint "$1" mytask7' "$meta" 2>/dev/null \
    && fail "a record without endpoint_task_id should refuse"
  printf 'endpoint_task_id=mytask7\n' >> "$meta"
  # A remote machine/t7 terminal can never be a recorded local endpoint.
  sed -i '' 's|^herdr_core_terminal=t7|herdr_core_terminal=machine/t7|' "$meta"
  run_dispatch "$dir" 'fm_backend_validate_task_endpoint "$1" mytask7' "$meta" 2>/dev/null \
    && fail "a machine/t7 terminal should refuse (remote addresses are never local endpoints)"
  sed -i '' 's|^herdr_core_terminal=machine/t7|herdr_core_terminal=t7|' "$meta"
  # window= must equal <session>:<terminal>.
  sed -i '' "s|^window=$SES:t7|window=$SES:t8|" "$meta"
  run_dispatch "$dir" 'fm_backend_validate_task_endpoint "$1" mytask7' "$meta" 2>/dev/null \
    && fail "a window/terminal mismatch should refuse"
  pass "endpoint meta: binds endpoint_task_id + session + terminal, refuses remote addresses and inconsistent windows"
}

# --- 20. ambient env isolation -------------------------------------------------------------------------

test_ambient_isolation() {
  local dir; dir=$(new_case amb)
  mkterm "$dir" t9 '.labels["fm.id"]="amb9"'
  # Ambient HC_* pointing at a DIFFERENT session+socket must not reach any call.
  env -i PATH="$dir/fakebin:$PATH" HOME="$dir/home" \
    FM_HC_BIN="$dir/fakebin/hc" FM_HC_LOG="$dir/log" FM_HC_FAKE_STATE="$dir/state" \
    FM_HC_SESSION="$SES" FM_HC_SOCKET="$SOCK" \
    HC_SESSION=ambient-session HC_SOCKET=/tmp/ambient.sock \
    HC_TERMINAL_ID=t99 HC_TERMINAL_SOCKET=/tmp/ambient-t.sock HC_SCOPE=ambient \
    FM_STATE_OVERRIDE="$dir/home-state" FM_HOME="$dir/home" \
    bash -c ". \"$ROOT/bin/backends/herdr-core.sh\"; fm_backend_herdr_core_target_ready '$SES:t9' fm-amb9" \
    || fail "target_ready should succeed under ambient HC_* noise"
  grep -F 'ambient-session' "$dir/log" \
    && fail "the ambient HC_SESSION leaked into an hc call"
  grep -F '/tmp/ambient.sock' "$dir/log" \
    && fail "the ambient HC_SOCKET leaked into an hc call"
  log_has "$dir" "HC_SESSION=$SES" || fail "the pinned session should reach every call"
  log_has "$dir" "HC_SOCKET=$SOCK" || fail "the pinned socket should reach every call"
  pass "ambient HC_* markers are stripped and every call pins the resolved session+socket"
}

# --- run -------------------------------------------------------------------------

fm_test_run \
  test_version_gate \
  test_session_rules \
  test_parse_target \
  test_generation_gate \
  test_create_task_labels \
  test_target_ready \
  test_pending_literal \
  test_pending_drop_on_clear \
  test_send_text_line \
  test_key_names \
  test_capture \
  test_current_path \
  test_agent_state \
  test_busy_state \
  test_submit \
  test_kill \
  test_list_live \
  test_dispatcher \
  test_endpoint_meta \
  test_ambient_isolation
