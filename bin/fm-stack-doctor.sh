#!/usr/bin/env bash
# Check every layer of a running local service stack in one command, so a
# diagnosis a reader would otherwise assemble from a chain of probes costs one
# run instead of twenty minutes.
#
# Usage:
#   bin/fm-stack-doctor.sh [--conf <path>] [--records] [--help]
#
# The stack to check is a list of layer records, so this command checks any
# layer rather than one project:
#
#   app     |name|port|health-url|source-dir|log-path
#   gateway |name|port|health-url|state-dir|log-path|front-port|front-name|session-port|session-log
#
# Every path is used exactly as written, so a relative log path resolves
# against the caller's working directory.
#
# The shipped default is the beads-bridge app behind the MCPJungle gateway,
# described in fm_sd_default_records below.
# A host overrides or extends it with FM_STACK_DOCTOR_CONF, or with
# config/stack-doctor.conf in its Firstmate home, where a later record with the
# same kind and name replaces the shipped one and a new kind or name adds a
# layer, so tracked code never carries one machine's own inventory.
# FM_STACK_DOCTOR_BUDGET sets the whole-run deadline in seconds, default 30.
#
# Every layer prints evidence, never a verdict about the reader's setup: a pid,
# a port, a bind address, an uptime, a deployed revision, a probe status, a URL,
# a session id, a tool count, a log path.
# Where a fact is unmeasurable on this host, the line says so with an explicit
# unknown or unmeasured marker rather than dropping the line, because a missing
# line reads as "nothing to report" when it usually means "not measured".
#
# Line protocol, one layer per line, stable for script consumers:
#   [tools]   <subject>  the probe tools this host has, and the resolved config
#   [app]     <name>     process, listen address, launchd label, working
#                        directory, deployed revision, health probe
#   [gateway] <name>     process, listen address, launchd label, health probe,
#                        the local reverse proxy fronting it, and the session
#                        proxy that logs the real caller ahead of it
#   [group]   <name>     included servers, endpoint, then the real handshake
#   [tailnet] <subject>  the same handshake again over the tailnet URL for every
#                        group, the public funnel answer for the same path, and
#                        the limits of what either one proves
#   [exposure] <subject> every tailscale serve and funnel mapping, which layer
#                        each reaches, and whether each layer is reachable from
#                        the tailnet, from the public internet, or neither
#   [traffic] <subject>  the newest request each log recorded, where it came
#                        from, and what the caller identity columns can prove;
#                        the session proxy log is read as it stood before this
#                        run's own probes, so the newest request is a real
#                        caller's and never the doctor's, and when no caller
#                        identity was recorded the line says the real client
#                        cannot be determined
#   [logs]    <subject>  what each log is authoritative for, the shape of the
#                        paths it records, and what it does not record
#   [summary] doctor     layer count, down count, elapsed time, verdict
#
# It exits non-zero when any layer is down, so it works as a check, and zero
# when every layer answered, including when an answer was an explicit unknown.
#
# This command is read-only apart from the MCP probes it must send to prove a
# route works: one initialize and one tools/list per group, which the gateway
# and its upstream servers record in their own logs.
set -eu

FM_SD_BUDGET=${FM_STACK_DOCTOR_BUDGET:-30}
FM_SD_STARTED=0
FM_SD_DOWN=0
FM_SD_LAYERS=0
FM_SD_LAST_UP=''
FM_SD_CONF=${FM_STACK_DOCTOR_CONF:-}

# Resolve this script's directory with builtins only, so a host missing a tool
# still reaches the report that names it.
SCRIPT_SELF=${BASH_SOURCE[0]}
SCRIPT_DIR=${SCRIPT_SELF%/*}
[ "$SCRIPT_DIR" != "$SCRIPT_SELF" ] || SCRIPT_DIR=.
SCRIPT_DIR=$(CDPATH='' cd -- "$SCRIPT_DIR" && pwd -P)

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

# shellcheck source=bin/fm-stack-doctor-lib.sh
. "$SCRIPT_DIR/fm-stack-doctor-lib.sh"

FM_SD_STARTED=$(fm_sd_epoch)
RECORDS_ONLY=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --conf)
      [ "$#" -ge 2 ] || usage
      FM_SD_CONF=$2
      shift 2
      ;;
    --records)
      RECORDS_ONLY=1
      shift
      ;;
    --help|-h) usage ;;
    *) usage ;;
  esac
done

if [ -z "$FM_SD_CONF" ] && [ -n "${FM_HOME:-}" ]; then
  FM_SD_CONF="$FM_HOME/config/stack-doctor.conf"
fi

# The shipped inventory: the reference beads-bridge app behind its MCPJungle
# gateway, with the gateway's loopback front in front of it.
# $HOME expands here, and every value is a documented default that a host
# config record replaces.
fm_sd_default_records() {
  cat <<EOF
app|beads-bridge|3737|http://127.0.0.1:3737/live/config|$HOME/.local/share/beads-bridge/app|$HOME/.local/share/beads-bridge/server.out.log
gateway|mcpjungle|8338|http://127.0.0.1:8338/health|$HOME/.local/share/mcpjungle|$HOME/.local/share/mcpjungle/gateway.out.log|8339|caddy|8337|$HOME/.local/share/mcpjungle/session-proxy.jsonl
EOF
}

# Print one field of a pipe-separated record by 1-based index.
# Reading fields by index keeps every record consumer from re-deriving the
# field order with a chain of shifts, which is where this shape breaks quietly.
fm_sd_field() { # <record> <1-based index>
  local -a fields
  IFS='|' read -r -a fields <<EOF
$1
EOF
  printf '%s' "${fields[$(($2 - 1))]-}"
}

# Print the port of a proxy target, whether it is a URL or a bare host:port.
fm_sd_target_port() { # <target>
  local target=${1#*://}
  target=${target%%/*}
  printf '%s' "${target##*:}"
}

# Print the resolved records, with a later record replacing an earlier record
# that names the same kind and name.
fm_sd_resolved_records() {
  local -a lines=() keys=()
  local line key slot index=0
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    key="$(fm_sd_field "$line" 1) $(fm_sd_field "$line" 2)"
    slot=''
    while [ "$index" -lt "${#keys[@]}" ]; do
      if [ "${keys[$index]}" = "$key" ]; then slot=$index; break; fi
      index=$((index + 1))
    done
    if [ -n "$slot" ]; then
      lines[slot]=$line
    else
      keys+=("$key")
      lines+=("$line")
      index=0
    fi
  done < <(
    fm_sd_default_records
    if [ -n "$FM_SD_CONF" ] && [ -f "$FM_SD_CONF" ]; then
      cat "$FM_SD_CONF"
    elif [ -n "$FM_SD_CONF" ]; then
      printf '# requested config does not exist: %s\n' "$FM_SD_CONF" >&2
    fi
  )
  index=0
  while [ "$index" -lt "${#lines[@]}" ]; do
    printf '%s\n' "${lines[$index]}"
    index=$((index + 1))
  done
}

# Return success while the whole-run deadline has not passed.
fm_sd_budget_left() {
  [ $(( $(fm_sd_epoch) - FM_SD_STARTED )) -lt "$FM_SD_BUDGET" ]
}

# Count one layer verdict and publish its word for the caller to interpolate.
# The counters live in this shell rather than inside a command substitution,
# because a subshell could not report back that a layer was down.
fm_sd_layer_note() { # <up:yes|no>
  FM_SD_LAYERS=$((FM_SD_LAYERS + 1))
  if [ "$1" != yes ]; then FM_SD_DOWN=$((FM_SD_DOWN + 1)); fi
  FM_SD_LAST_UP=$1
}

# --- app layer -------------------------------------------------------------

# Report one long-running HTTP app: the process holding its port, what that
# process is, and whether its own health endpoint answers.
check_app() { # <name> <port> <health-url> <source-dir> <log-path>
  local name=$1 port=$2 health=$3 source=$4
  local pid listen facts probe up
  pid=$(fm_sd_port_pid "$port")
  listen=$(fm_sd_listen_addr "$port")
  if [ -n "$pid" ]; then
    facts=$(fm_sd_process_facts "$pid")
  else
    facts='pid=none uptime=unknown state=no-listener'
  fi
  probe=$(fm_sd_http_probe "$health" 3)
  if [ -n "$pid" ] && printf '%s' "$probe" | grep -q 'status=200'; then up=yes; else up=no; fi
  fm_sd_layer_note "$up"
  # The probe helpers each return several key=value tokens, which the line
  # protocol wants as separate arguments rather than one quoted blob.
  # shellcheck disable=SC2086
  fm_sd_emit app "$name" \
    "port=$port" "listen=${listen:-none}" $facts \
    "launchd=$( [ -n "$pid" ] && fm_sd_launchd_label "$pid" || printf unknown )" \
    "cwd=$( [ -n "$pid" ] && fm_sd_cwd "$pid" || printf unknown )" \
    "$( if [ -n "$pid" ]; then fm_sd_git_facts "$source"; else printf 'revision=unknown reason=no-process'; fi )" \
    "probe_url=$health" $probe "up=$FM_SD_LAST_UP"
}

# --- gateway layer ---------------------------------------------------------

# Report every tool group a gateway publishes, then prove each one completes a
# real MCP initialize handshake and list its tools.
# A reader who guessed the wrong group name loses the run, so the group names,
# the servers behind them, and their endpoints all print before any handshake.
check_gateway_groups() { # <gateway-name> <base-url> <serve-json>
  local name=$1 base=$2 serve=$3
  if ! command -v jq >/dev/null 2>&1; then
    fm_sd_emit group "$name" status=unknown reason=jq-absent
    fm_sd_layer_note unknown
    return 0
  fi
  local body
  body=$(curl -s -m 3 "$base/api/v0/tool-groups" 2>/dev/null) || body=''
  if ! printf '%s' "$body" | jq -e 'type == "array"' >/dev/null 2>&1; then
    fm_sd_emit group "$name" status=unknown \
      "inventory_url=$base/api/v0/tool-groups" "result=$(fm_sd_one_line "$body" 100)" \
      'reason=group-inventory-unavailable (the gateway health line separates a dead gateway from a changed API)'
    fm_sd_layer_note unknown
    return 0
  fi
  fm_sd_emit group "$name" status=listed \
    "groups=$(printf '%s' "$body" | jq 'length' 2>/dev/null || printf unknown)" \
    "names=$(printf '%s' "$body" | jq -r '[.[].name] | join(", ")' 2>/dev/null || printf unknown)"
  local group detail endpoint handshake up
  while IFS= read -r group; do
    [ -n "$group" ] || continue
    detail=$(curl -s -m 3 "$base/api/v0/tool-groups/$group" 2>/dev/null) || detail=''
    endpoint=$(printf '%s' "$detail" | jq -r '.streamable_http_endpoint // empty' 2>/dev/null || true)
    if [ -z "$endpoint" ]; then
      fm_sd_emit group "$group" status=unknown \
        "servers=$(printf '%s' "$body" | jq -r --arg g "$group" '(map(select(.name == $g))[0].included_servers) // [] | join(", ")' 2>/dev/null || printf unknown)" \
        'endpoint=unresolved reason=group-detail-unavailable'
      fm_sd_layer_note unknown
      continue
    fi
    if ! fm_sd_budget_left; then
      fm_sd_emit group "$group" handshake=skipped "endpoint=$endpoint" \
        "reason=the ${FM_SD_BUDGET}s whole-run budget was exhausted before this group"
      fm_sd_layer_note unknown
      continue
    fi
    handshake=$(fm_sd_mcp_probe "$endpoint" 4)
    if printf '%s' "$handshake" | grep -q 'handshake=ok'; then up=yes; else up=no; fi
    fm_sd_layer_note "$up"
    # shellcheck disable=SC2086
    fm_sd_emit group "$group" \
      "servers=$(printf '%s' "$detail" | jq -r '(.included_servers // []) | join(", ")' 2>/dev/null || printf unknown)" \
      "endpoint=$endpoint" $handshake "up=$FM_SD_LAST_UP"
    check_tailnet_group "$name" "$group" "$endpoint" "$serve"
  done < <(printf '%s' "$body" | jq -r '.[].name' 2>/dev/null)
}

# Report the local reverse proxy a gateway is published through, because that
# front is the process which silently collapses the caller address.
check_front() { # <gateway-name> <front-name> <front-port>
  local gateway=$1 front=$2 port=$3
  local pid facts cmd config access up
  pid=$(fm_sd_port_pid "$port")
  if [ -n "$pid" ]; then
    facts=$(fm_sd_process_facts "$pid")
    up=yes
  else
    facts='pid=none uptime=unknown state=no-listener'
    up=no
  fi
  cmd=$( [ -n "$pid" ] && fm_sd_cmdline "$pid" || printf unknown )
  config=$(printf '%s' "$cmd" | tr ' ' '\n' | awk 'seen { print; exit } $0 == "--config" || $0 == "-config" { seen = 1 }')
  access=unknown
  if [ -n "$config" ] && [ -f "$config" ]; then
    if grep -q -E '^[[:space:]]*log[[:space:]]' "$config"; then
      access=configured
    else
      access=absent
    fi
  fi
  fm_sd_layer_note "$up"
  # shellcheck disable=SC2086
  fm_sd_emit gateway "$gateway" \
    "front=$front" "front_port=$port" \
    "front_listen=$( [ -n "$pid" ] && fm_sd_listen_addr "$port" || printf none )" $facts \
    "front_launchd=$( [ -n "$pid" ] && fm_sd_launchd_label "$pid" || printf unknown )" \
    "front_config=${config:-unknown}" "front_access_log=$access" \
    "front_command=\"$(fm_sd_one_line "$cmd" 120)\"" "up=$FM_SD_LAST_UP"
}

# Print the URL path of an endpoint, which is how a local gateway endpoint maps
# onto the tailnet and funnel entries that front the same routes.
fm_sd_url_path() { # <url>
  local url=${1#*://}
  case "$url" in
    */*) printf '/%s' "${url#*/}" ;;
    *) printf '/' ;;
  esac
}

# Print the tailnet base URL a gateway is published under, from the serve
# mapping that proxies to a port this gateway owns.
# A tailscale-served endpoint must be addressed by hostname: a raw tailnet IP
# fails TLS SNI, which a probe would report as a false route failure.
fm_sd_gateway_tailnet_base() { # <gateway-name> <serve-json>
  local gname=$1 json=$2 host path target funnel port layer
  [ -n "$json" ] || return 1
  while IFS='|' read -r host path target funnel; do
    [ "$path" = tcp ] && continue
    port=$(fm_sd_target_port "$target")
    layer=$(fm_sd_layer_for_port "$port")
    case "$layer" in
        "gateway:$gname"|"gateway:$gname-front")
        printf 'https://%s%s' "$host" "$path"
        return 0
        ;;
    esac
  done < <(fm_sd_serve_mappings "$json")
  return 1
}

# Print the public funnel base URL and the layer it reaches, when one is on.
fm_sd_gateway_funnel_base() { # <gateway-name> <serve-json>
  local gname=$1 json=$2 host path target funnel port layer
  [ -n "$json" ] || return 1
  while IFS='|' read -r host path target funnel; do
    [ "$funnel" = yes ] || continue
    port=$(fm_sd_target_port "$target")
    layer=$(fm_sd_layer_for_port "$port")
    printf 'https://%s%s|%s' "$host" "$path" "$layer"
    return 0
  done < <(fm_sd_serve_mappings "$json")
  return 1
}

# Report that a tailscale-served endpoint is addressed by hostname.
# The failure this prevents is invisible in the output: a probe by tailnet IP
# returns a TLS error that reads exactly like a broken route.
fm_sd_emit_addressing_note() { # <url>
  local url=${1#https://} host=${1#https://}
  host=${host%%/*}
  case "$host" in
    ''|*[!0-9.]*) return 0 ;;
  esac
  fm_sd_emit tailnet addressing note="this route was probed by address, not by name" "url=$url" \
    'consequence=a tailscale-served endpoint addressed by raw tailnet IP fails TLS SNI, so a failure from this probe cannot be read as a route fault'
}

# Report every group's MCP route again over the tailnet entry point, and the
# public funnel answer for the same path.
#
# The handshake must complete over the tailnet, not merely return 200, because
# a front can answer a status for a route that never became an MCP session.
report_tailnet_routes() { # <gateway-name> <serve-json>
  local gname=$1 serve=$2
  local tailnet_base funnel_base funnel_layer limitation
  if ! tailnet_base=$(fm_sd_gateway_tailnet_base "$gname" "$serve"); then
    fm_sd_emit tailnet "$gname" tailnet_route status=absent \
      'reason=no tailscale serve mapping proxies to a port this gateway owns, so there is no tailnet route to test'
    fm_sd_layer_note no
    return 0
  fi
  fm_sd_emit tailnet "$gname" tailnet_route status=published "base_url=$tailnet_base" \
    'addressing=hostname (a raw tailnet IP would fail TLS SNI and report a false route failure)'
  fm_sd_emit_addressing_note "$tailnet_base"
  limitation='every machine in this fleet is on the tailnet, so a request made from this host proves the tailnet route works and proves nothing at all about an off-tailnet caller'
  fm_sd_emit tailnet "$gname" limitation="this route test runs from $(hostname 2>/dev/null || printf unknown) on the tailnet itself" \
    "cannot_prove=$limitation"
  local record kind name
  while IFS= read -r record; do
    kind=$(fm_sd_field "$record" 1)
    name=$(fm_sd_field "$record" 2)
    [ "$kind" = gateway ] || continue
    [ "$name" = "$gname" ] || continue
    if funnel_base=$(fm_sd_gateway_funnel_base "$gname" "$serve"); then
      funnel_layer=${funnel_base##*|}
      funnel_base=${funnel_base%|*}
    else
      funnel_layer=none
      funnel_base=unknown
    fi
    fm_sd_emit tailnet "$gname" funnel_route "base_url=$funnel_base" "serves=$funnel_layer" \
      "reaches_this_gateway=$( [ "$funnel_layer" = "gateway:$gname" ] && printf yes || printf no )"
  done < <(fm_sd_resolved_records)
}

# Probe one group's MCP route over the tailnet and, when a funnel entry exists,
# over the funnel as well.
check_tailnet_group() { # <gateway-name> <group> <local-endpoint> <serve-json>
  local gname=$1 group=$2 endpoint=$3 serve=$4
  local tailnet_base url handshake up
  local path
  path=$(fm_sd_url_path "$endpoint")
  if ! tailnet_base=$(fm_sd_gateway_tailnet_base "$gname" "$serve"); then
    fm_sd_emit tailnet group "$group" url=unknown handshake=skipped \
      'reason=this gateway has no tailnet entry point to probe'
    fm_sd_layer_note no
    return 0
  fi
  url="${tailnet_base%/}$path"
  handshake=$(fm_sd_mcp_probe "$url" 6)
  if printf '%s' "$handshake" | grep -q 'handshake=ok'; then up=yes; else up=no; fi
  fm_sd_layer_note "$up"
  # shellcheck disable=SC2086
  fm_sd_emit tailnet group "$group" "url=$url" \
    "local_endpoint=$endpoint" $handshake "up=$FM_SD_LAST_UP"
  fm_sd_check_funnel_route "$gname" "$group" "$path" "$serve"
}

# Report what the public funnel returns for one group's MCP path.
# A funnel that serves a different layer answers with that layer's own verdict,
# which is a fact about the exposure map rather than a fault in this group.
fm_sd_check_funnel_route() { # <gateway-name> <group> <path> <serve-json>
  local gname=$1 group=$2 path=$3 serve=$4
  local pair base layer code body
  if ! pair=$(fm_sd_gateway_funnel_base "$gname" "$serve"); then
    fm_sd_emit tailnet funnel group "$group" url=unknown http=unprobed \
      'reason=no funnel mapping is published on this host, so there is no public route to report'
    return 0
  fi
  base=${pair%|*}
  layer=${pair##*|}
  if [ "$layer" != "gateway:$gname" ]; then
    code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "${base%/}$path" 2>/dev/null) || code=''
    body=$(curl -s -m 5 "${base%/}$path" 2>/dev/null) || body=''
    fm_sd_emit tailnet funnel group "$group" "url=${base%/}$path" "http=${code:-no-response}" \
      "serves=$layer" \
      "verdict=mismatch" \
      "public_body=\"$(fm_sd_one_line "$body" 120)\"" \
      "reason=the public funnel serves $layer, not this gateway, so this path never reaches a group route; the gateway is reachable over the tailnet only"
    return 0
  fi
  code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "${base%/}$path" 2>/dev/null) || code=''
  fm_sd_emit tailnet funnel group "$group" "url=${base%/}$path" "http=${code:-no-response}" \
    "serves=$layer" 'verdict=the funnel does reach this gateway; the handshake result for this route is the tailnet line above'
}

check_gateway() { # <name> <port> <health-url> <state-dir> <log-path> <front-port> <front-name> <serve-json>
  local name=$1 port=$2 health=$3 state=$4
  local serve=$8
  local pid listen facts probe up base
  pid=$(fm_sd_port_pid "$port")
  listen=$(fm_sd_listen_addr "$port")
  if [ -n "$pid" ]; then
    facts=$(fm_sd_process_facts "$pid")
  else
    facts='pid=none uptime=unknown state=no-listener'
  fi
  probe=$(fm_sd_http_probe "$health" 3)
  if [ -n "$pid" ] && printf '%s' "$probe" | grep -q 'status=200'; then up=yes; else up=no; fi
  base=${health%/health}
  fm_sd_layer_note "$up"
  # shellcheck disable=SC2086
  fm_sd_emit gateway "$name" \
    "port=$port" "listen=${listen:-none}" $facts \
    "launchd=$( [ -n "$pid" ] && fm_sd_launchd_label "$pid" || printf unknown )" \
    "state_dir=$state" "probe_url=$health" $probe "up=$FM_SD_LAST_UP"
  if [ "$FM_SD_LAST_UP" != yes ]; then
    fm_sd_emit group "$name" status=unknown \
      'reason=gateway-down (no group can be listed or handshaken while the gateway is down)'
    fm_sd_layer_note unknown
    return 0
  fi
  report_tailnet_routes "$name" "$serve"
  check_gateway_groups "$name" "$base" "$serve"
  if [ -n "${6:-}" ]; then
    check_front "$name" "${7:-front}" "$6"
  fi
  if [ -n "${9:-}" ]; then
    check_session_proxy "$name" "$9" "${10:-}"
  fi
}

# Report the session proxy that logs the real caller ahead of the gateway.
# It sits between the front and the gateway, so when it is down every request
# through the front fails while the gateway still answers directly.
check_session_proxy() { # <gateway-name> <session-port> <session-log>
  local gateway=$1 port=$2 log=${3:-}
  local pid facts up
  pid=$(fm_sd_port_pid "$port")
  if [ -n "$pid" ]; then
    facts=$(fm_sd_process_facts "$pid")
    up=yes
  else
    facts='pid=none uptime=unknown state=no-listener'
    up=no
  fi
  fm_sd_layer_note "$up"
  # shellcheck disable=SC2086
  fm_sd_emit gateway "$gateway" \
    session_proxy=yes "session_proxy_port=$port" \
    "session_proxy_listen=$( [ -n "$pid" ] && fm_sd_listen_addr "$port" || printf none )" $facts \
    "session_proxy_launchd=$( [ -n "$pid" ] && fm_sd_launchd_label "$pid" || printf unknown )" \
    "session_proxy_log=${log:-unknown}" "up=$FM_SD_LAST_UP"
}

# --- exposure layer --------------------------------------------------------

# Name the layer a proxied loopback port belongs to, or unknown.
# This is what turns a serve mapping into "the tailnet reaches the gateway"
# instead of a bare port number.
fm_sd_layer_for_port() { # <port>
  local port=$1 record kind name layer_port front session
  while IFS= read -r record; do
    kind=$(fm_sd_field "$record" 1)
    name=$(fm_sd_field "$record" 2)
    case "$kind" in
      app)
        layer_port=$(fm_sd_field "$record" 3)
        if [ "$layer_port" = "$port" ]; then printf 'app:%s' "$name"; return 0; fi
        ;;
      gateway)
        layer_port=$(fm_sd_field "$record" 3)
        front=$(fm_sd_field "$record" 7)
        if [ "$layer_port" = "$port" ]; then printf 'gateway:%s' "$name"; return 0; fi
        if [ -n "$front" ] && [ "$front" = "$port" ]; then printf 'gateway:%s-front' "$name"; return 0; fi
        session=$(fm_sd_field "$record" 9)
        if [ -n "$session" ] && [ "$session" = "$port" ]; then printf 'gateway:%s-session-proxy' "$name"; return 0; fi
        ;;
    esac
  done < <(fm_sd_resolved_records)
  printf 'unknown'
}

report_exposure() { # <serve-json>
  local json=$1 host path target funnel kind port layer
  if [ -z "$json" ]; then
    fm_sd_layer_note unknown
    return 0
  fi
  local tailnet_gateway='' public_gateway='' public_app=''
  while IFS='|' read -r host path target funnel; do
    [ -n "$host" ] || continue
    kind=serve
    port=$(fm_sd_target_port "$target")
    if [ "$funnel" = yes ]; then kind=funnel; else kind=serve; fi
    layer=$(fm_sd_layer_for_port "$port")
    case "$layer" in
      gateway:*)
        if [ "$funnel" = yes ]; then public_gateway="$layer"; else tailnet_gateway="$layer"; fi
        ;;
      app:*)
        [ "$funnel" = yes ] && public_app="$layer"
        ;;
    esac
    if [ "$path" = tcp ]; then
      fm_sd_emit exposure "$kind" "url=tcp://$host" "forwards_to=$target" \
        "local_port=$port" "layer=$layer"
    else
      fm_sd_emit exposure "$kind" "url=https://$host$path" "proxies_to=$target" \
        "local_port=$port" "layer=$layer"
    fi
  done < <(fm_sd_serve_mappings "$json")
  local record kind name
  while IFS= read -r record; do
    kind=$(fm_sd_field "$record" 1)
    name=$(fm_sd_field "$record" 2)
    [ "$kind" = gateway ] || continue
    case "$tailnet_gateway" in
      "gateway:$name"*) tail=yes ;;
      *) tail=no ;;
    esac
    case "$public_gateway" in
      "gateway:$name"*) pub=yes ;;
      *) pub=no ;;
    esac
    fm_sd_layer_note yes
    fm_sd_emit exposure gateway "$name" "reachable_from_tailnet=$tail" "reachable_from_public=$pub" \
      "note=$( [ "$pub" = no ] && printf 'no funnel mapping reaches this gateway, so the public funnel serves a different layer' || printf 'a funnel mapping reaches this gateway' )"
  done < <(fm_sd_resolved_records)
  [ -z "$public_app" ] || fm_sd_emit exposure funnel-summary "public_funnel_serves=$public_app"
}

# --- traffic layer ---------------------------------------------------------

# Report the newest request the session proxy recorded, and where it came from.
# This is the one log that sees the real caller, because it reads the
# X-Forwarded-For chain and the Tailscale identity headers the gateway's own
# log never records.
# Only the lines present when this run began are read (FM_SD_SESSION_LINES), so
# the newest request is a real caller's rather than this run's own probe.
# An unreadable or absent log is printed as unknown rather than counted as a
# down layer, because missing evidence is not a failed service.
# Session ids and header values are never printed: presented session ids as
# presence only, and the identity headers as the tailnet login and name the
# proxy already logged.
report_session_traffic() { # <gateway-name> <session-log>
  local gname=$1 log=${2:-} lines window newest attributed total attributed_count mcp_newest
  if [ -z "$log" ]; then
    fm_sd_emit traffic "$gname" session_proxy log=unknown \
      'conclusion=no session proxy log is configured, so the real client of the newest request cannot be determined from any log'
    return 0
  fi
  if [ ! -f "$log" ]; then
    fm_sd_emit traffic "$gname" session_proxy "log=$log" status=absent \
      'conclusion=the session proxy log does not exist, so the real client of the newest request cannot be determined from any log'
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    fm_sd_emit traffic "$gname" session_proxy "log=$log" status=unknown reason=jq-absent \
      'conclusion=the session proxy log cannot be parsed without jq, so the real client of the newest request cannot be determined'
    return 0
  fi
  lines=${FM_SD_SESSION_LINES:-0}
  window=$(head -n "$lines" "$log" 2>/dev/null | tail -n 5000 | jq -R -c 'fromjson? | select(type == "object")' 2>/dev/null || true)
  newest=$(printf '%s\n' "$window" | jq -c 'select(.event == "request")' 2>/dev/null | tail -1)
  total=$(printf '%s\n' "$window" | jq -c 'select(.event == "request")' 2>/dev/null | wc -l | tr -d ' ')
  attributed=$(printf '%s\n' "$window" | jq -c 'select(.event == "request" and ((.tailscale_login // "") != "" or ((.client // "127.0.0.1") | . != "127.0.0.1" and . != "::1")))' 2>/dev/null | tail -1)
  mcp_newest=$(printf '%s\n' "$window" | jq -c 'select(.event == "request" and (.rpc // "") != "")' 2>/dev/null | tail -1)
  attributed_count=$(printf '%s\n' "$window" | jq -c 'select(.event == "request" and ((.tailscale_login // "") != "" or ((.client // "127.0.0.1") | . != "127.0.0.1" and . != "::1")))' 2>/dev/null | wc -l | tr -d ' ')
  if [ -z "$newest" ]; then
    fm_sd_emit traffic "$gname" session_proxy "log=$log" status=empty "requests_read=0" \
      'conclusion=the session proxy log held no request record when this run began, so the real client cannot be determined'
    return 0
  fi
  fm_sd_layer_note yes
  fm_sd_emit traffic "$gname" session_proxy_newest "log=$log" "requests_read=$total" \
    "$(fm_sd_session_request_facts "$newest" "$window")"
  if [ -n "$mcp_newest" ]; then
    fm_sd_emit traffic "$gname" session_proxy_newest_mcp "$(fm_sd_session_request_facts "$mcp_newest" "$window")"
  else
    fm_sd_emit traffic "$gname" session_proxy_newest_mcp \
      'requests_with_jsonrpc_method=0 conclusion=no request in the window carried a JSON-RPC method, so no MCP call was seen'
  fi
  if [ -n "$attributed" ]; then
    fm_sd_emit traffic "$gname" session_proxy_newest_attributed "requests_with_caller_identity=$attributed_count" \
      "$(fm_sd_session_request_facts "$attributed" "$window")" \
      'conclusion=a request in this log carries a tailnet login or a non-loopback client, so a caller identity was recorded for it'
  else
    fm_sd_emit traffic "$gname" session_proxy_newest_attributed requests_with_caller_identity=0 \
      'conclusion=no request in the window carries a tailnet login or a non-loopback client, so the real client cannot be determined'
  fi
}

# Print the evidence tokens of one session-proxy request record, with the
# response the proxy logged for the same request id.
fm_sd_session_request_facts() { # <request-json> <window-json-lines>
  printf '%s' "$1" | jq -r --argjson window "$(printf '%s\n' "$2" | jq -s -c '.' 2>/dev/null || printf '[]')" '
    . as $r
    | ($window | map(select(.event == "response" and .rid == $r.rid)) | last // {}) as $s
    | [ "at=\($r.ts // "unknown")",
        "rid=\($r.rid // "unknown")",
        "method=\($r.method // "unknown")",
        "path=\($r.path // "unknown")",
        "group=\(if ($r.group // "") == "" then "none" else $r.group end)",
        "rpc=\(if ($r.rpc // "") == "" then "none" else $r.rpc end)",
        "client=\($r.client // "unknown")",
        "forwarded_for=\($r.forwarded_for // "unknown")",
        "tailscale_login=\(if ($r.tailscale_login // "") == "" then "none" else $r.tailscale_login end)",
        "user_agent=\"\($r.user_agent // "unknown")\"",
        "session=\(if ($r.session // "absent") == "absent" then "absent" else "presented" end)",
        "status=\($s.status // "unknown")",
        "verdict=\($s.verdict // "unknown")" ]
    | join(" ")' 2>/dev/null || printf 'facts=unparseable'
}

# Report the newest request each log recorded, and prove what its caller column
# can and cannot identify.
#
# The gateway logs a client address that any loopback proxying front controls,
# so the doctor measures rather than assumes: one request through the tailnet
# front shows what the log records for a real tailnet caller, and one request
# carrying a synthetic X-Forwarded-For shows which header the column follows.
report_traffic() { # <gateway-name> <gateway-log> <gateway-port> <app-name> <app-log> <front-port> <serve-json> <session-log>
  local gname=$1 glog=$2 gport=$3 aname=$4 alog=$5 front_port=${6:-} json=$7 slog=${8:-}
  local last clients identity_lines
  last=$(fm_sd_log_last "$glog" '\| (GET|POST) ')
  clients=''
  if [ -f "$glog" ]; then
    clients=$(tail -200 "$glog" 2>/dev/null | awk -F'|' '
      NF >= 4 {
        addr = $4
        gsub(/^[ \t]+|[ \t]+$/, "", addr)
        if (addr != "" && !seen[addr]++) { out = out (out == "" ? "" : ",") addr }
      }
      END { print out }')
  fi
  identity_lines=$(fm_sd_log_count "$glog" 'Tailscale-User-Login')
  fm_sd_emit traffic "$gname" "log=$glog" \
    "last_request=\"$(fm_sd_one_line "$last" 140)\"" \
    "distinct_clients_last_200_lines=${clients:-unknown}" \
    "lines_recording_tailscale_user_header=$identity_lines"
  report_session_traffic "$gname" "$slog"
  local host path target funnel front_url code logged port layer
  if [ -n "$json" ]; then
    while IFS='|' read -r host path target funnel; do
      [ "$path" = tcp ] && continue
      port=$(fm_sd_target_port "$target")
      layer=$(fm_sd_layer_for_port "$port")
      case "$layer" in
        "gateway:$gname"|"gateway:$gname-front") ;;
        *) continue ;;
      esac
      front_url="https://$host$path"
      break
    done < <(fm_sd_serve_mappings "$json")
  fi
  if [ -n "${front_url:-}" ] && fm_sd_budget_left; then
    code=$(curl -s -m 4 -o /dev/null -w '%{http_code}' "${front_url}health" 2>/dev/null) || code=''
    logged=$(fm_sd_log_last "$glog" '/health' | awk -F'|' '{ addr = $4; gsub(/^[ \t]+|[ \t]+$/, "", addr); print addr }')
    fm_sd_layer_note yes
    curl -s -m 4 -o /dev/null "$front_url/health" >/dev/null 2>&1 || true
    fm_sd_layer_note yes
    fm_sd_emit traffic "$gname" tailnet_front_probe "url=${front_url}health" \
      "http=${code:-no-response}" "logged_client=${logged:-unknown}" \
      "conclusion=$( [ -n "$logged" ] && printf 'a request that arrived through the tailnet front is recorded as %s, so this column cannot separate a tailnet caller from a public one' "$logged" || printf 'this run could not observe what the front records for a tailnet caller, so the column remains unmeasured' )"
  else
    fm_sd_emit traffic "$gname" tailnet_front_probe "url=${front_url:-unknown}" \
      "reason=$( [ -z "${front_url:-}" ] && printf 'no tailscale serve mapping proxies to a port this gateway owns' || printf 'the whole-run budget was exhausted before this probe' )"
    fm_sd_layer_note unknown
  fi
  if fm_sd_budget_left; then
    curl -s -m 4 -o /dev/null -H 'X-Forwarded-For: 203.0.113.9' \
      "http://127.0.0.1:$gport/health" >/dev/null 2>&1 || true
    local xff
    xff=$(fm_sd_log_last "$glog" '/health' | awk -F'|' '{ addr = $4; gsub(/^[ \t]+|[ \t]+$/, "", addr); print addr }')
    fm_sd_layer_note yes
    fm_sd_emit traffic "$gname" client_column_probe "sent_x_forwarded_for=203.0.113.9" \
      "logged_client=${xff:-unknown}" \
      "conclusion=$( [ "$xff" = 203.0.113.9 ] && printf 'the logged client column follows X-Forwarded-For, so a front that preserved the real caller address would show it here' || printf 'the logged client column did not follow the X-Forwarded-For this run sent, so it comes from somewhere this probe did not identify' )"
  else
    fm_sd_emit traffic "$gname" client_column_probe skipped \
      'reason=the whole-run budget was exhausted before this probe'
    fm_sd_layer_note unknown
  fi
  local mcp_lines mcp_last live_last front_pid front_label front_paths front_log caller_lines xff_lines newest
  front_log=''
  if [ -n "$front_port" ]; then
    front_pid=$(fm_sd_port_pid "$front_port")
    front_label=$( [ -n "$front_pid" ] && fm_sd_launchd_label "$front_pid" || printf unknown )
    front_paths=$(fm_sd_launchd_log_paths "$front_label")
    front_log=$(printf '%s' "$front_paths" | sed -n 's/.*launchd_standard_error=\([^ ]*\).*/\1/p')
  fi
  if [ -n "$front_log" ] && [ -f "$front_log" ]; then
    caller_lines=$(fm_sd_log_count "$front_log" 'Tailscale-User-Login')
    xff_lines=$(fm_sd_log_count "$front_log" 'X-Forwarded-For')
    newest=$(fm_sd_log_last "$front_log" 'Tailscale-User-Login|X-Forwarded-For')
    fm_sd_emit traffic "$gname" front_log_caller_evidence "log=$front_log" \
      "lines_recording_tailscale_user=$caller_lines" "lines_recording_x_forwarded_for=$xff_lines" \
      "newest_caller_header_line=\"$(fm_sd_one_line "$newest" 200)\"" \
      'note=this front only writes a request record when it logs a warning or error, so these lines are a sample of failed or aborted requests rather than a request history'
  else
    fm_sd_emit traffic "$gname" front_log_caller_evidence \
      "log=${front_log:-unknown}" "lines_recording_tailscale_user=unreadable" \
      'note=no front log was readable at its launchd error path, so no caller identity header was recovered from any layer'
  fi
  mcp_lines=$(fm_sd_log_count "$alog" "$FM_SD_MCP_ERE")
  mcp_last=$(fm_sd_log_last "$alog" "$FM_SD_MCP_ERE")
  live_last=$(fm_sd_log_last "$alog" ' /live/')
  fm_sd_layer_note yes
  fm_sd_emit traffic "$aname" "log=$alog" "mcp_request_lines=$mcp_lines" \
    "last_mcp_request=\"$(fm_sd_one_line "$mcp_last" 140)\"" \
    "last_live_request=\"$(fm_sd_one_line "$live_last" 140)\""
}

# --- logs layer ------------------------------------------------------------

report_logs() {
  local record kind name port health source log path
  while IFS= read -r record; do
    kind=$(fm_sd_field "$record" 1)
    name=$(fm_sd_field "$record" 2)
    case "$kind" in
      app)
        port=$(fm_sd_field "$record" 3)
        health=$(fm_sd_field "$record" 4)
        source=$(fm_sd_field "$record" 5)
        log=$(fm_sd_field "$record" 6)
        fm_sd_emit_log logs "$name" "$log" \
          'the app own inbound HTTP requests: method, path, status, ip, user-agent, duration' \
          'which gateway tool group a caller used, and the gateway own view; an MCP call appears here only as an inbound request line, so a log dominated by another path can hide it'
        local mcp_lines
        mcp_lines=$(fm_sd_log_count "$log" "$FM_SD_MCP_ERE")
        fm_sd_emit logs "$name" "mcp_request_lines=$mcp_lines" \
          "note=$( [ "$mcp_lines" -eq 0 ] && printf 'this log recorded no MCP request line at all, so its silence about MCP is not evidence that MCP was unused' || printf 'this log does record MCP request lines; read them by path rather than from the newest lines' )"
        fm_sd_emit logs "$name" 'note=the path histogram follows as path=<path> lines=<count> last_seen=<first field of that line>'
        local count last
        while IFS='|' read -r path count last; do
          [ -n "$path" ] || continue
          fm_sd_emit logs "$name" "path=$path" "lines=$count" "last_seen=$last"
        done < <(fm_sd_log_paths "$log" 6)
        ;;
      gateway)
        port=$(fm_sd_field "$record" 3)
        log=$(fm_sd_field "$record" 6)
        fm_sd_emit_log logs "$name" "$log" \
          'the MCP requests that reached this gateway: status, duration, path, and the client column the traffic layer measures' \
          'the real caller address behind a loopback proxying front, and upstream server-side effects, which live in the app log and in any front access log'
        local front_port front_name front_pid front_label paths front_log session_log
        session_log=$(fm_sd_field "$record" 10)
        front_port=$(fm_sd_field "$record" 7)
        front_name=$(fm_sd_field "$record" 8)
        if [ -n "$front_port" ]; then
          front_pid=$(fm_sd_port_pid "$front_port")
          front_label=$( [ -n "$front_pid" ] && fm_sd_launchd_label "$front_pid" || printf unknown )
          paths=$(fm_sd_launchd_log_paths "$front_label")
          fm_sd_emit logs "$name-front(${front_name:-front})" "port=$front_port" \
            "launchd_label=$front_label" \
            "launchd_log_paths=${paths:-unreadable}"
          front_log=$(printf '%s' "$paths" | sed -n 's/.*launchd_standard_error=\([^ ]*\).*/\1/p')
          fm_sd_emit_log logs "$name-front(${front_name:-front})" "${front_log:-unknown}" \
            'this front own startup, TLS and upstream-failure diagnostics, which are the only request records it keeps while no access log is configured' \
            'request volume, status codes, or caller identity: with no access log the front records no successful request at all, so its silence about a caller proves nothing'
        fi
        if [ -n "$session_log" ]; then
          fm_sd_emit_log logs "$name-session-proxy" "$session_log" \
            'every request that came through the front: the real client from X-Forwarded-For and Tailscale identity headers, whether a session id was presented, the JSON-RPC method, the response status, and the failure shape' \
            'whether the gateway executed the tool call, upstream server-side effects, and any request that reached the gateway or the app by another route; the app log, not this one, shows the app side'
        else
          fm_sd_emit logs "$name-session-proxy" log=unknown \
            'note=no session proxy log is configured, so no log names the real caller of a request'
        fi
        ;;
      *)
        fm_sd_emit logs "$name" "record=$kind" status=unknown reason='no log contract is defined for this record kind'
        ;;
    esac
  done < <(fm_sd_resolved_records)
}

# --- run -------------------------------------------------------------------

if [ "$RECORDS_ONLY" -eq 1 ]; then
  fm_sd_resolved_records
  exit 0
fi

# The regular expression that identifies an inbound MCP request line in an app
# request log, stated once so the traffic and logs layers count the same lines.
FM_SD_MCP_ERE='(GET|POST) /(mcp|chatgpt/mcp|jungle/mcp)([?[:space:]]|$)'

fm_sd_emit tools run "budget=${FM_SD_BUDGET}s" \
  "config=${FM_SD_CONF:-shipped-defaults}" \
  "records=$(fm_sd_resolved_records | wc -l | tr -d ' ')"
fm_sd_report_tools curl jq lsof ps git tailscale launchctl

# Read the tailscale mapping once and report why it is missing, rather than
# letting each layer discover its absence separately.
SERVE_JSON=''
SERVE_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-stack-doctor-serve.XXXXXX")
# The call runs in this shell, not in a command substitution, because the
# reason it failed travels back in a variable a subshell could not set.
fm_sd_serve_json > "$SERVE_FILE" || true
SERVE_JSON=$(cat "$SERVE_FILE" 2>/dev/null || printf '')
rm -f "$SERVE_FILE"
if [ -n "$SERVE_JSON" ]; then
  fm_sd_emit exposure tailscale status=read
else
  fm_sd_emit exposure tailscale "status=absent" "reason=${FM_SD_SERVE_REASON:-unknown}" \
    'consequence=the exposure and tailnet-route layers cannot name what this host publishes, and say so rather than reporting no mappings'
  fm_sd_layer_note unknown
fi

APP_NAME='' APP_LOG='' GATEWAY_NAME='' GATEWAY_LOG='' GATEWAY_PORT='' GATEWAY_FRONT_PORT='' GATEWAY_SESSION_LOG=''
# The session proxy log is measured before any probe below, so its newest
# request is a real caller's rather than this run's own handshake.
FM_SD_SESSION_LINES=0
while IFS= read -r record; do
  if [ "$(fm_sd_field "$record" 1)" = gateway ]; then
    log=$(fm_sd_field "$record" 10)
    if [ -n "$log" ] && [ -f "$log" ]; then
      FM_SD_SESSION_LINES=$(wc -l < "$log" 2>/dev/null | tr -d ' ')
    fi
  fi
done < <(fm_sd_resolved_records)
while IFS= read -r record; do
  kind=$(fm_sd_field "$record" 1)
  name=$(fm_sd_field "$record" 2)
  case "$kind" in
    app)
      check_app "$name" \
        "$(fm_sd_field "$record" 3)" "$(fm_sd_field "$record" 4)" \
        "$(fm_sd_field "$record" 5)" "$(fm_sd_field "$record" 6)"
      APP_NAME=$name
      APP_LOG=$(fm_sd_field "$record" 6)
      ;;
    gateway)
      check_gateway "$name" \
        "$(fm_sd_field "$record" 3)" "$(fm_sd_field "$record" 4)" "$(fm_sd_field "$record" 5)" \
        "$(fm_sd_field "$record" 6)" \
        "$(fm_sd_field "$record" 7)" "$(fm_sd_field "$record" 8)" "$SERVE_JSON" \
        "$(fm_sd_field "$record" 9)" "$(fm_sd_field "$record" 10)"
      GATEWAY_NAME=$name
      GATEWAY_SESSION_LOG=$(fm_sd_field "$record" 10)
      GATEWAY_LOG=$(fm_sd_field "$record" 6)
      GATEWAY_PORT=$(fm_sd_field "$record" 3)
      GATEWAY_FRONT_PORT=$(fm_sd_field "$record" 7)
      ;;
    *)
      fm_sd_emit layer "$kind" "$name" status=unknown reason='this record kind is not implemented'
      fm_sd_layer_note unknown
      ;;
  esac
done < <(fm_sd_resolved_records)

report_exposure "$SERVE_JSON"

if [ -n "$GATEWAY_LOG" ] && [ -n "$APP_LOG" ]; then
  report_traffic "$GATEWAY_NAME" "$GATEWAY_LOG" "$GATEWAY_PORT" "$APP_NAME" "$APP_LOG" "$GATEWAY_FRONT_PORT" "$SERVE_JSON" "$GATEWAY_SESSION_LOG"
else
  fm_sd_emit traffic stack skipped \
    'reason=no app-and-gateway pair is configured, so this run has no gateway log and app log to correlate'
  fm_sd_layer_note unknown
fi

report_logs

fm_sd_emit_summary "$FM_SD_DOWN" "$FM_SD_LAYERS"
[ "$FM_SD_DOWN" -eq 0 ]