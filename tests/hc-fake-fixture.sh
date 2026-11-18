#!/usr/bin/env bash
# tests/hc-fake-fixture.sh - a stateful fake herdr-core (`hc`) CLI for suites
# that drive a remote second mate's host-local control plane.
#
# write_hc_fake_cli <bin-path> <D-assignment-line> emits the fake; the
# assignment line fixes the fake's state directory, so a caller can bake it
# into the script when the environment between the test and the fake is
# scrubbed (a remote job runs under env -i).
#
# Terminals live as <D>/<address>.json. `run` allocates the next address and
# stores the labels and cwd it was given, `get` answers not_found with exit 3,
# `kill` marks a terminal finished, `rm` removes it, `ls` lists live terminals
# filtered by --label (finished ones only with --all), `server status --json`
# reports the core, and `connect` answers the generation handshake. A `send`
# models a registered agent: the terminal's foreground becomes the harness
# named in <D>/harness, which is how a launched mate reads alive. Every call
# is logged with its HC_SESSION and XDG_RUNTIME_DIR to <D>/log, fields
# separated by \x1f.
#
# Control files under <D>:
#   harness        - the agent `send` starts (default claude)
#   keeps-running  - keeps_running_after_logout in `server status` (default true;
#                    `absent` omits the field)
#   version        - what `--version` reports (default 0.1.21)
#   generation     - the handshake generation (default 1)
#   send-refuses   - when present, `send` fails

write_hc_fake_cli() {
  local bin=$1 dline=$2
  mkdir -p "$(dirname "$bin")"
  cat > "$bin" <<EOF
#!/usr/bin/env bash
$dline
EOF
  cat >> "$bin" <<'SH'
set -u
mkdir -p "$D"
{ printf 'HC_SESSION=%s\x1fXDG_RUNTIME_DIR=%s' "${HC_SESSION:-}" "${XDG_RUNTIME_DIR:-}"; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "$D/log"
cmd=${1:-}
last=''
for a in "$@"; do last=$a; done
case "$cmd" in
  --version) printf 'hc %s\n' "$(cat "$D/version" 2>/dev/null || printf 0.1.21)" ;;
  server)
    case "${2:-}" in
      status)
        keeps=$(cat "$D/keeps-running" 2>/dev/null || printf true)
        if [ "$keeps" = absent ]; then
          printf '{"pid":1,"version":"0.1.21"}\n'
        else
          printf '{"pid":1,"version":"0.1.21","keeps_running_after_logout":%s}\n' "$keeps"
        fi
        ;;
      *) printf '{}\n' ;;
    esac
    ;;
  connect)
    IFS= read -r _ || true
    printf '{"jsonrpc":"2.0","id":1,"result":{"generation":%s}}\n' "$(cat "$D/generation" 2>/dev/null || printf 1)"
    ;;
  ls)
    all=0; want=()
    shift
    while [ $# -gt 0 ]; do
      case "$1" in
        --all) all=1 ;;
        --label) want+=("$2"); shift ;;
      esac
      shift
    done
    out='[]'
    for f in "$D"/t*.json; do
      [ -e "$f" ] || continue
      [ "$all" = 1 ] || [ "$(jq -r .state "$f")" = live ] || continue
      ok=1
      for kv in ${want[@]+"${want[@]}"}; do
        [ "$(jq -r --arg k "${kv%%=*}" '.labels[$k] // ""' "$f")" = "${kv#*=}" ] || ok=0
      done
      [ "$ok" = 1 ] || continue
      out=$(jq -c --slurpfile t "$f" '. + [$t[0] | {address, state}]' <<<"$out")
    done
    printf '{"terminals":%s}\n' "$out"
    ;;
  run)
    n=$(cat "$D/next" 2>/dev/null || printf 1)
    printf '%s\n' $((n + 1)) > "$D/next"
    addr="t$n"; cwd=/; labels='{}'
    shift
    while [ $# -gt 0 ]; do
      case "$1" in
        --cwd) cwd=$2; shift ;;
        --label) labels=$(jq -c --arg k "${2%%=*}" --arg v "${2#*=}" '.[$k]=$v' <<<"$labels"); shift ;;
      esac
      shift
    done
    jq -n --arg a "$addr" --arg c "$cwd" --argjson l "$labels" \
      '{address:$a, state:"live", name:null, labels:$l, cwd:$c, foreground:{name:"zsh", argv:["/bin/zsh"], cwd:$c, pid:1}, status:{state:"idle"}}' > "$D/$addr.json"
    printf '{"address":"%s"}\n' "$addr"
    ;;
  get)
    [ -f "$D/$last.json" ] || { printf '{"error":{"kind":"not_found"}}\n' >&2; exit 3; }
    cat "$D/$last.json"
    ;;
  kill)
    [ -f "$D/$last.json" ] || { printf '{"error":{"kind":"not_found"}}\n' >&2; exit 3; }
    jq '.state="finished" | .foreground=null' "$D/$last.json" > "$D/$last.tmp" && mv "$D/$last.tmp" "$D/$last.json"
    printf '{}\n'
    ;;
  rm) rm -f "$D/$last.json"; printf '{}\n' ;;
  read) printf '\xe2\x9d\xaf\n' ;;
  send)
    [ ! -e "$D/send-refuses" ] || { printf '{"error":{"kind":"refused"}}\n' >&2; exit 1; }
    target=''
    shift
    while [ $# -gt 0 ]; do
      case "$1" in
        --) break ;;
        --*) ;;
        *) [ -n "$target" ] || target=$1 ;;
      esac
      shift
    done
    if [ -n "$target" ] && [ -f "$D/$target.json" ]; then
      h=$(cat "$D/harness" 2>/dev/null || printf claude)
      jq --arg h "$h" '.foreground={name:$h, argv:[$h], cwd:.cwd, pid:1}' "$D/$target.json" > "$D/$target.tmp" \
        && mv "$D/$target.tmp" "$D/$target.json"
      printf '%s\n' "$*" >> "$D/sent"
    fi
    printf '{"started":true,"wait":{"status":"working"}}\n'
    ;;
  *) printf '{}\n' ;;
esac
SH
  chmod +x "$bin"
}
