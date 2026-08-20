#!/usr/bin/env bash
# fm-miniapp-deploy.sh - install, inspect or remove the Telegram Mini App
# decision surface on its host.
#
#   fm-miniapp-deploy.sh deploy     install/refresh service, page and Caddy block
#   fm-miniapp-deploy.sh status     is the service up, does the address answer
#   fm-miniapp-deploy.sh rollback   remove all three again, leaving no residue
#   fm-miniapp-deploy.sh render     print the rendered Caddy block, touch nothing
#
# Configuration comes from a local file, by default ~/.config/fm-miniapp.env,
# overridable with FM_MINIAPP_CONFIG. Every value may also come from the
# environment. Nothing has a default that points at a real bot, chat or host:
# an unset value refuses the run.
#
#   FM_MINIAPP_SSH          ssh destination of the host          (e.g. hetzner)
#   FM_MINIAPP_ADDRESS      public hostname, no scheme
#   FM_MINIAPP_LISTEN       host:port the service binds ON THE HOST
#   FM_MINIAPP_UPSTREAM     host:port Caddy proxies to  (default = LISTEN)
#   FM_MINIAPP_OWNER_ID     the only Telegram user id allowed to answer
#   FM_MINIAPP_CHANNEL      the <channel> part of the answer filename
#   FM_MINIAPP_TOKEN_FILE   local file holding the bot token   (never uploaded
#                           wholesale; only the one variable below is read)
#   FM_MINIAPP_TOKEN_VAR    variable name inside that file      (e.g. TG_POOL_05)
#   FM_MINIAPP_CADDY_DIR    remote dir with Caddyfile + caddy-projekte
#                                                       (default ~/quiz-web)
#   FM_MINIAPP_REMOTE_ROOT  remote install dir       (default /root/fm-miniapp)
#   FM_MINIAPP_NEIGHBOURS   space-separated https URLs of OTHER sites on the
#                           same Caddy, probed before and after the reload
#
# Why the Caddy part looks so careful: on the reference host a single Caddy
# serves 18 addresses across several projects, two of them customer domains, and
# an invalid configuration takes all of them down at once. So this script never
# touches the root Caddyfile, writes only its own snippet file, validates the
# whole resulting configuration in a throwaway container BEFORE the file reaches
# the directory Caddy reads, and probes neighbouring addresses before and after
# the reload. A changed neighbour status fails the run loudly instead of leaving
# a quiet outage behind.
#
# The bot token is read from the local file at deploy time and written to a
# root-owned 0600 file on the host. It is never echoed, never passed on a
# command line, and never committed.
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export FM_MINIAPP_TOOL=fm-miniapp-deploy

# shellcheck source=bin/fm-miniapp-lib.sh
. "$SCRIPT_DIR/fm-miniapp-lib.sh"

usage() { sed -n '2,/^set -/p' "$0" | sed 's/^# \{0,1\}//; $d'; }

die() { fm_miniapp_die "$1"; }

note() { printf '  %s\n' "$1"; }

load_config() {
  fm_miniapp_load_config FM_MINIAPP_SSH FM_MINIAPP_ADDRESS FM_MINIAPP_LISTEN \
    FM_MINIAPP_OWNER_ID FM_MINIAPP_CHANNEL FM_MINIAPP_TOKEN_FILE FM_MINIAPP_TOKEN_VAR
  : "${FM_MINIAPP_UPSTREAM:=$FM_MINIAPP_LISTEN}"
  : "${FM_MINIAPP_CADDY_DIR:=\$HOME/quiz-web}"
  : "${FM_MINIAPP_REMOTE_ROOT:=/root/fm-miniapp}"
  : "${FM_MINIAPP_NEIGHBOURS:=}"
}

read_token() { fm_miniapp_read_token; }

on_host() { fm_miniapp_on_host "$@"; }

probe() { fm_miniapp_probe "$1"; }

probe_neighbours() {
  local url
  for url in $FM_MINIAPP_NEIGHBOURS; do probe "$url"; done
}

# --- rendering --------------------------------------------------------------

render_snippet() {
  local template=$SCRIPT_DIR/fm-miniapp.caddy.template
  [ -f "$template" ] || die "template missing: $template"
  sed -e "s|__ADDRESS__|$FM_MINIAPP_ADDRESS|g" \
    -e "s|__UPSTREAM__|$FM_MINIAPP_UPSTREAM|g" "$template"
}

render_unit() {
  cat <<UNIT
[Unit]
Description=Telegram Mini App decision surface (firstmate)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=$FM_MINIAPP_REMOTE_ROOT/env
ExecStart=/usr/bin/python3 $FM_MINIAPP_REMOTE_ROOT/fm-miniapp-serve.py
WorkingDirectory=$FM_MINIAPP_REMOTE_ROOT
Restart=on-failure
RestartSec=5
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
UNIT
}

# --- deploy -----------------------------------------------------------------

cmd_deploy() {
  local token before after
  token=$(read_token)

  printf 'Neighbours before:\n'
  before=$(probe_neighbours)
  [ -n "$before" ] && printf '%s\n' "$before" | sed 's/^/  /'

  printf 'Installing service and page...\n'
  tar -C "$SCRIPT_DIR" -cf - fm-telegram-verify.py fm-miniapp-serve.py fm-miniapp \
    | on_host "umask 077 && mkdir -p '$FM_MINIAPP_REMOTE_ROOT' && tar -C '$FM_MINIAPP_REMOTE_ROOT' -xf -"

  # The token reaches the host over the ssh channel on stdin, never as an
  # argument: arguments are visible in the host's process list.
  printf 'FM_MINIAPP_BOT_TOKEN=%s\nFM_MINIAPP_OWNER_ID=%s\nFM_MINIAPP_CHANNEL=%s\nFM_MINIAPP_LISTEN=%s\nFM_MINIAPP_QUESTIONS=%s/questions\nFM_MINIAPP_ANSWERS=%s/answers\nFM_MINIAPP_WEB=%s/fm-miniapp\n' \
    "$token" "$FM_MINIAPP_OWNER_ID" "$FM_MINIAPP_CHANNEL" "$FM_MINIAPP_LISTEN" \
    "$FM_MINIAPP_REMOTE_ROOT" "$FM_MINIAPP_REMOTE_ROOT" "$FM_MINIAPP_REMOTE_ROOT" \
    | on_host "umask 077 && cat > '$FM_MINIAPP_REMOTE_ROOT/env.tmp' && chmod 600 '$FM_MINIAPP_REMOTE_ROOT/env.tmp' && mv '$FM_MINIAPP_REMOTE_ROOT/env.tmp' '$FM_MINIAPP_REMOTE_ROOT/env'"

  render_unit | on_host "cat > /etc/systemd/system/fm-miniapp.service"
  on_host 'systemctl daemon-reload && systemctl enable --now fm-miniapp.service && systemctl restart fm-miniapp.service'
  note "service: $(on_host 'systemctl is-active fm-miniapp.service' || true)"

  # The service must answer on the host before the address is published; a Caddy
  # block in front of a dead port is the same "does not load" from outside.
  on_host "curl -sS -o /dev/null -m 10 -w 'local probe %{http_code}\n' 'http://$FM_MINIAPP_LISTEN/'" \
    | sed 's/^/  /'

  printf 'Validating the Caddy configuration with the new block...\n'
  # The snippet travels as an argument, base64-encoded: the remote script
  # already occupies stdin, and a multi-line value cannot be quoted safely
  # through a shell on the far side of ssh.
  local snippet_b64
  snippet_b64=$(render_snippet | base64 | tr -d '\n')
  on_host "bash -s -- '$FM_MINIAPP_CADDY_DIR' '$snippet_b64'" <<'REMOTE'
set -Eeuo pipefail
umask 077
CADDY_DIR=${1/\$HOME/$HOME}
SNIPPET=$(printf '%s' "$2" | base64 -d)

CANDIDATE=$(mktemp -d)
ENVFILE=$(mktemp /tmp/fm-miniapp-caddy-env.XXXXXX)
trap 'rm -rf "$CANDIDATE"; rm -f "$ENVFILE"' EXIT

cp "$CADDY_DIR/Caddyfile" "$CANDIDATE/Caddyfile"
mkdir -p "$CANDIDATE/projekte"
if compgen -G "$CADDY_DIR/caddy-projekte/*.caddy" >/dev/null; then
  cp "$CADDY_DIR"/caddy-projekte/*.caddy "$CANDIDATE/projekte/"
fi
printf '%s\n' "$SNIPPET" >"$CANDIDATE/projekte/fm-miniapp.caddy"

# docker run --env-file does not strip the quotes compose strips, so a bcrypt
# hash would reach the container with its quotes and the run would fail on a
# problem that is not ours.
sed "s/^\([A-Za-z_][A-Za-z0-9_]*\)='\(.*\)'$/\1=\2/" "$CADDY_DIR/.env" >"$ENVFILE" 2>/dev/null || :
# </dev/null on every docker call is load-bearing, not tidiness: this
# script reaches the host on stdin, and `docker compose exec -T` attaches
# stdin - it swallowed the rest of this file once, so the reload below
# never ran and the failure was completely silent.
docker run --rm --env-file "$ENVFILE" -v "$CANDIDATE":/etc/caddy:ro caddy:2-alpine \
  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null </dev/null
echo "  candidate validates"

# Only now does the file reach the directory Caddy reads, and it arrives whole:
# a partially written file there would be picked up by any restart in the gap.
mkdir -p "$CADDY_DIR/caddy-eingang" "$CADDY_DIR/caddy-sicherungen"
if [ -f "$CADDY_DIR/caddy-projekte/fm-miniapp.caddy" ]; then
  cp -a "$CADDY_DIR/caddy-projekte/fm-miniapp.caddy" \
    "$CADDY_DIR/caddy-sicherungen/fm-miniapp.caddy.bak-$(date -u +%Y%m%dT%H%M%SZ)"
fi
printf '%s\n' "$SNIPPET" >"$CADDY_DIR/caddy-eingang/fm-miniapp.caddy"
# Readable like its neighbour in that directory: the block holds no secret,
# and a 0600 file there depends on Caddy happening to run as root.
chmod 644 "$CADDY_DIR/caddy-eingang/fm-miniapp.caddy"
mv "$CADDY_DIR/caddy-eingang/fm-miniapp.caddy" "$CADDY_DIR/caddy-projekte/fm-miniapp.caddy"

cd "$CADDY_DIR"
docker compose exec -T caddy caddy validate --config /etc/caddy/Caddyfile >/dev/null </dev/null
docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile </dev/null
echo "  caddy reloaded"
REMOTE

  printf 'Neighbours after:\n'
  after=$(probe_neighbours)
  [ -n "$after" ] && printf '%s\n' "$after" | sed 's/^/  /'
  if [ "$before" != "$after" ]; then
    die "neighbouring addresses changed across the reload - investigate before continuing"
  fi

  # Caddy obtains the certificate on the first request to a new name, so the
  # address is briefly unreachable after the reload. Waiting is the difference
  # between reporting a deployment failure and reporting earliness.
  printf 'Waiting for the address to answer...\n'
  local waited=0 status
  while [ "$waited" -lt 60 ]; do
    status=$(probe "https://$FM_MINIAPP_ADDRESS/")
    case "$status" in
      *' ERR'|*' 000'*) sleep 3; waited=$((waited + 3)) ;;
      *) break ;;
    esac
  done

  printf 'The address:\n'
  note "$(probe "https://$FM_MINIAPP_ADDRESS/")"
  note "$(probe "https://$FM_MINIAPP_ADDRESS/app.js")"
}

# --- status -----------------------------------------------------------------

cmd_status() {
  note "service: $(on_host 'systemctl is-active fm-miniapp.service' 2>/dev/null || echo absent)"
  note "block:   $(on_host "test -f ${FM_MINIAPP_CADDY_DIR}/caddy-projekte/fm-miniapp.caddy && echo installed || echo absent" 2>/dev/null || echo unknown)"
  note "$(probe "https://$FM_MINIAPP_ADDRESS/")"
}

# --- rollback ---------------------------------------------------------------

cmd_rollback() {
  printf 'Removing the Caddy block...\n'
  on_host "bash -s -- '$FM_MINIAPP_CADDY_DIR'" <<'REMOTE'
set -Eeuo pipefail
CADDY_DIR=${1/\$HOME/$HOME}
if [ -f "$CADDY_DIR/caddy-projekte/fm-miniapp.caddy" ]; then
  mkdir -p "$CADDY_DIR/caddy-sicherungen"
  mv "$CADDY_DIR/caddy-projekte/fm-miniapp.caddy" \
    "$CADDY_DIR/caddy-sicherungen/fm-miniapp.caddy.removed-$(date -u +%Y%m%dT%H%M%SZ)"
  cd "$CADDY_DIR"
  docker compose exec -T caddy caddy validate --config /etc/caddy/Caddyfile >/dev/null </dev/null
  docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile </dev/null
  echo "  block removed, caddy reloaded"
else
  echo "  no block installed"
fi
REMOTE

  printf 'Removing the service...\n'
  on_host "bash -s -- '$FM_MINIAPP_REMOTE_ROOT'" <<'REMOTE'
set -Eeuo pipefail
ROOT=$1
systemctl disable --now fm-miniapp.service 2>/dev/null || true
rm -f /etc/systemd/system/fm-miniapp.service
systemctl daemon-reload
# shred the token file rather than unlinking it.
if [ -f "$ROOT/env" ]; then shred -u "$ROOT/env" 2>/dev/null || rm -f "$ROOT/env"; fi
rm -rf "$ROOT"
echo "  service and install directory removed"
REMOTE
  note "$(probe "https://$FM_MINIAPP_ADDRESS/")"
}

# --- entry point ------------------------------------------------------------

main() {
  local command=${1:-}
  case "$command" in
    deploy) load_config; cmd_deploy ;;
    status) load_config; cmd_status ;;
    rollback) load_config; cmd_rollback ;;
    render) load_config; render_snippet ;;
    -h|--help|'') usage ;;
    *) die "unknown command: $command (try --help)" ;;
  esac
}

main "$@"
