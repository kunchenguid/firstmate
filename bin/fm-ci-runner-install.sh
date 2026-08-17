#!/usr/bin/env bash
# fm-ci-runner-install.sh - install or remove the fork's dedicated Actions runner.
#
# Usage:
#   fm-ci-runner-install.sh install --repository pedromuller-del/firstmate --token-stdin
#   fm-ci-runner-install.sh uninstall --repository pedromuller-del/firstmate --token-stdin
#   fm-ci-runner-install.sh diagnose-registration --token-stdin --runner-exit N --runner-output PATH
#   fm-ci-runner-install.sh dependencies
#   fm-ci-runner-install.sh status
#
# Run `install` and `uninstall` as root.
# Pipe the one-use GitHub registration or removal token on standard input with
# `--token-stdin`; the script never writes it to disk or echoes it.
# Repository runner registration requires a classic PAT carrying `repo` and
# `workflow` scopes; fine-grained-PAT-minted `api_` tokens are diagnosed before
# any host mutation because GitHub's runner-registration endpoint rejects them.
#
# The install is repository-scoped, names and labels the runner `water-7`, and
# runs it as the dedicated `fm-ci-runner` system user from
# `/opt/actions-runner-water-7`.
# The account is password-locked and has no SSH credentials, but its command
# shell is `/bin/bash` because tmux and Herdr CI tests must start real panes.
# A nologin shell makes those panes exit immediately and is not an isolation
# boundary: Actions jobs already execute arbitrary commands as this account.
# GitHub's official v2.336.0 Linux x64 tarball is checksum-verified before use.
# The official svc.sh owns systemd unit creation; a drop-in caps CI at six CPUs
# and lowers its CPU and I/O priority so it cannot stampede fleet workers.
# Re-running install converges service enablement when the matching runner is
# already configured.
set -eu

RUNNER_VERSION=2.336.0
RUNNER_SHA256=04cf0be1aff4c3ec3554466c39124ca250e3effd8873bb7e8d68535aa9505d5d
RUNNER_ARCHIVE="actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
RUNNER_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${RUNNER_ARCHIVE}"
RUNNER_MAX_BYTES=250000000
RUNNER_REPOSITORY=pedromuller-del/firstmate
RUNNER_NAME=water-7
RUNNER_LABEL=water-7
RUNNER_USER=fm-ci-runner
RUNNER_GROUP=fm-ci-runner
RUNNER_HOME=/var/lib/fm-ci-runner
RUNNER_SHELL=/bin/bash
RUNNER_DIR=/opt/actions-runner-water-7
INSTALL_MARKER="$RUNNER_DIR/.fm-ci-install"
RUNNER_DOWNLOAD_TMP=

usage() {
  sed -n '2,/^set -eu$/{/^set -eu$/d;s/^# \{0,1\}//;p;}' "$0"
}

die() {
  printf 'fm-ci-runner-install.sh: %s\n' "$*" >&2
  exit 1
}

require_root() {
  [ "$(id -u)" -eq 0 ] || die "must run as root"
}

cleanup_runner_download() {
  local cleanup_path=${RUNNER_DOWNLOAD_TMP:-}
  [ -n "$cleanup_path" ] || return 0
  case "$cleanup_path" in
    /opt/fm-ci-runner-download.*) ;;
    *)
      printf 'fm-ci-runner-install.sh: refusing unsafe download cleanup path: %s\n' "$cleanup_path" >&2
      RUNNER_DOWNLOAD_TMP=
      return 0
      ;;
  esac
  if [ -d "$cleanup_path" ] && [ ! -L "$cleanup_path" ]; then
    find "$cleanup_path" -mindepth 1 -depth -delete 2>/dev/null \
      || printf 'fm-ci-runner-install.sh: warning: could not empty download directory %s\n' "$cleanup_path" >&2
    rmdir "$cleanup_path" 2>/dev/null \
      || printf 'fm-ci-runner-install.sh: warning: could not remove download directory %s\n' "$cleanup_path" >&2
  fi
  RUNNER_DOWNLOAD_TMP=
  return 0
}
trap cleanup_runner_download EXIT

MISSING_PACKAGES=()
add_missing_package() {
  local candidate=$1 present
  for present in "${MISSING_PACKAGES[@]+"${MISSING_PACKAGES[@]}"}"; do
    [ "$present" = "$candidate" ] && return
  done
  MISSING_PACKAGES+=("$candidate")
}

collect_missing_packages() {
  local requirement command_name package
  MISSING_PACKAGES=()
  [ -r /etc/ssl/certs/ca-certificates.crt ] || add_missing_package ca-certificates
  for requirement in \
    curl:curl \
    getent:libc-bin \
    git:git \
    groupadd:passwd \
    groupdel:passwd \
    jq:jq \
    node:nodejs \
    npm:nodejs \
    python3:python3 \
    runuser:util-linux \
    sha256sum:coreutils \
    systemctl:systemd \
    tar:tar \
    tmux:tmux \
    useradd:passwd \
    usermod:passwd \
    xz:xz-utils; do
    command_name=${requirement%%:*}
    package=${requirement#*:}
    command -v "$command_name" >/dev/null 2>&1 || add_missing_package "$package"
  done
  if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import yaml' >/dev/null 2>&1; then
    add_missing_package python3-yaml
  fi
}

print_missing_packages() {
  local package
  collect_missing_packages
  for package in "${MISSING_PACKAGES[@]+"${MISSING_PACKAGES[@]}"}"; do
    printf '%s\n' "$package"
  done
}

validate_repository() {
  [ "$REPOSITORY" = "$RUNNER_REPOSITORY" ] \
    || die "repository must be the approved fork $RUNNER_REPOSITORY"
}

read_token() {
  [ "$TOKEN_STDIN" -eq 1 ] || die "--token-stdin is required; tokens are never accepted from arguments"
  IFS= read -r TOKEN || true
  [ -n "${TOKEN:-}" ] || die "received an empty one-use token"
}

registration_token_is_fine_grained() {
  local token=$1
  [[ "$token" == api_* && "${#token}" -eq 70 ]]
}

fine_grained_token_diagnosis() {
  printf '%s\n' \
    'fine-grained PAT minted this runner registration token, but GitHub runner-registration rejects that token class.' \
    'Authenticate gh-axi with a classic PAT carrying repo and workflow scopes, then mint a new one-use repository runner registration token.'
}

validate_registration_token() {
  local token=$1
  if registration_token_is_fine_grained "$token"; then
    fine_grained_token_diagnosis >&2
    return 1
  fi
}

registration_output_is_404() {
  local output=$1
  case "$output" in
    *runner-registration*404*|*404*runner-registration*) return 0 ;;
    *) return 1 ;;
  esac
}

report_registration_result() {
  local token=$1 output=$2 runner_exit=$3
  [ "$runner_exit" -ne 0 ] || return 0
  if registration_token_is_fine_grained "$token"; then
    fine_grained_token_diagnosis >&2
    return 1
  fi
  if registration_output_is_404 "$output"; then
    printf '%s\n' \
      'runner-registration returned 404.' \
      'GitHub rejects registration tokens minted through a fine-grained PAT on this repository.' \
      'Authenticate gh-axi with a classic PAT carrying repo and workflow scopes, then mint a fresh one-use registration token.' >&2
    return 1
  fi
  printf 'runner registration failed with exit %s; the runner output above is the authoritative cause.\n' \
    "$runner_exit" >&2
  return 1
}

diagnose_registration() {
  local output bytes
  read_token
  case "$RUNNER_EXIT" in
    ''|*[!0-9]*) die "--runner-exit must be a non-negative integer" ;;
  esac
  [ -n "$RUNNER_OUTPUT" ] && [ -f "$RUNNER_OUTPUT" ] && [ ! -L "$RUNNER_OUTPUT" ] \
    || die "--runner-output must name a regular non-symlink file"
  bytes=$(wc -c <"$RUNNER_OUTPUT" | tr -d '[:space:]')
  [ "$bytes" -le 65536 ] || die "--runner-output exceeds the 65536-byte diagnostic bound"
  output=$(<"$RUNNER_OUTPUT")
  report_registration_result "$TOKEN" "$output" "$RUNNER_EXIT"
}

marker_matches() {
  [ -f "$INSTALL_MARKER" ] || return 1
  [ "$(sed -n '1p' "$INSTALL_MARKER")" = "repository=$RUNNER_REPOSITORY" ] || return 1
  [ "$(sed -n '2p' "$INSTALL_MARKER")" = "name=$RUNNER_NAME" ] || return 1
  [ "$(sed -n '3p' "$INSTALL_MARKER")" = "label=$RUNNER_LABEL" ] || return 1
}

service_name() {
  local name
  [ -f "$RUNNER_DIR/.service" ] || return 1
  name=$(tr -d '\r\n' <"$RUNNER_DIR/.service")
  case "$name" in
    actions.runner.*.service) printf '%s\n' "$name" ;;
    *) return 1 ;;
  esac
}

install_service() {
  local service dropin
  cd "$RUNNER_DIR"
  if ! service=$(service_name); then
    ./svc.sh install "$RUNNER_USER"
    service=$(service_name) || die "official svc.sh did not publish a valid systemd unit name"
  fi
  dropin="/etc/systemd/system/${service}.d"
  install -d -o root -g root -m 0755 "$dropin"
  install -o root -g root -m 0644 /dev/null "$dropin/firstmate-resource-boundary.conf"
  printf '%s\n' \
    '[Service]' \
    'CPUQuota=600%' \
    'Nice=10' \
    'IOSchedulingClass=best-effort' \
    'IOSchedulingPriority=6' \
    >"$dropin/firstmate-resource-boundary.conf"
  systemctl daemon-reload
  systemctl enable --now "$service"
  systemctl is-enabled "$service"
  systemctl is-active "$service"
}

ensure_runner_account() {
  local account account_home account_shell account_group account_groups
  if ! getent group "$RUNNER_GROUP" >/dev/null 2>&1; then
    groupadd --system "$RUNNER_GROUP"
  fi
  if ! id "$RUNNER_USER" >/dev/null 2>&1; then
    useradd --system --gid "$RUNNER_GROUP" --create-home --home-dir "$RUNNER_HOME" \
      --shell "$RUNNER_SHELL" "$RUNNER_USER"
  fi
  account=$(getent passwd "$RUNNER_USER") || die "could not read the dedicated runner account"
  account_home=$(printf '%s\n' "$account" | awk -F: '{print $6}')
  account_shell=$(printf '%s\n' "$account" | awk -F: '{print $7}')
  account_group=$(id -gn "$RUNNER_USER")
  account_groups=$(id -Gn "$RUNNER_USER")
  [ "$account_home" = "$RUNNER_HOME" ] \
    || die "existing $RUNNER_USER account does not use the dedicated home $RUNNER_HOME"
  [ "$account_group" = "$RUNNER_GROUP" ] && [ "$account_groups" = "$RUNNER_GROUP" ] \
    || die "$RUNNER_USER must have only its dedicated $RUNNER_GROUP group"
  if [ "$account_shell" != "$RUNNER_SHELL" ]; then
    usermod --shell "$RUNNER_SHELL" "$RUNNER_USER"
  fi
  usermod --lock "$RUNNER_USER"
  account=$(getent passwd "$RUNNER_USER") || die "could not re-read the dedicated runner account"
  account_shell=$(printf '%s\n' "$account" | awk -F: '{print $7}')
  [ "$account_shell" = "$RUNNER_SHELL" ] \
    || die "could not set $RUNNER_USER command shell to $RUNNER_SHELL"
  install -d -o "$RUNNER_USER" -g "$RUNNER_USER" -m 0750 "$RUNNER_HOME"
}

install_runner() {
  local actual private_path
  local registration_log registration_output registration_rc
  validate_repository
  read_token
  validate_registration_token "$TOKEN" || exit 1
  require_root

  [ "$(uname -s)" = Linux ] || die "water-7 requires Linux"
  [ "$(uname -m)" = x86_64 ] || die "water-7 requires x86_64"
  collect_missing_packages
  if [ "${#MISSING_PACKAGES[@]}" -gt 0 ]; then
    command -v apt-get >/dev/null 2>&1 || die "missing dependencies require Ubuntu's apt-get"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y "${MISSING_PACKAGES[@]}"
  fi
  for command in curl getent git groupadd groupdel jq node npm python3 sha256sum tar tmux useradd usermod runuser systemctl; do
    command -v "$command" >/dev/null 2>&1 || die "required command is missing: $command"
  done
  python3 -c 'import yaml' >/dev/null 2>&1 || die "python3-yaml is unavailable after installation"

  ensure_runner_account

  if marker_matches && [ -f "$RUNNER_DIR/.runner" ]; then
    install_service
    TOKEN=
    printf 'fm-ci-runner-install.sh: water-7 already configured; service converged\n'
    return
  fi
  [ ! -e "$RUNNER_DIR/.runner" ] \
    || die "runner credentials exist without the matching install marker; uninstall with a removal token before retrying"

  install -d -o "$RUNNER_USER" -g "$RUNNER_USER" -m 0750 "$RUNNER_DIR"
  for private_path in /home/fm/.config/gh/hosts.yml /home/fm/.ssh /home/fm/fm-home/data; do
    runuser -u "$RUNNER_USER" -- test ! -r "$private_path" \
      || die "runner-to-fleet isolation failed: $RUNNER_USER can read $private_path"
  done
  find "$RUNNER_DIR" -mindepth 1 -depth -delete

  RUNNER_DOWNLOAD_TMP=$(mktemp -d /opt/fm-ci-runner-download.XXXXXX)
  curl -fsSL --max-filesize "$RUNNER_MAX_BYTES" "$RUNNER_URL" -o "$RUNNER_DOWNLOAD_TMP/$RUNNER_ARCHIVE" \
    || die "official runner download failed"
  actual=$(sha256sum "$RUNNER_DOWNLOAD_TMP/$RUNNER_ARCHIVE" | awk '{print $1}')
  [ "$actual" = "$RUNNER_SHA256" ] \
    || die "runner checksum mismatch (expected $RUNNER_SHA256, got $actual)"
  tar -xzf "$RUNNER_DOWNLOAD_TMP/$RUNNER_ARCHIVE" -C "$RUNNER_DIR" --no-same-owner
  chown -R "$RUNNER_USER:$RUNNER_USER" "$RUNNER_DIR"
  chmod 0750 "$RUNNER_DIR"

  "$RUNNER_DIR/bin/installdependencies.sh"
  registration_log="$RUNNER_DOWNLOAD_TMP/registration.out"
  set +e
  # shellcheck disable=SC2016 # Positional parameters expand in the child shell.
  runuser -u "$RUNNER_USER" -- bash -c '
    cd "$1"
    exec ./config.sh --unattended --url "$2" --token "$3" --name "$4" --labels "$5" --work _work --replace
  ' _ "$RUNNER_DIR" "https://github.com/$RUNNER_REPOSITORY" "$TOKEN" "$RUNNER_NAME" "$RUNNER_LABEL" \
    >"$registration_log" 2>&1
  registration_rc=$?
  set -e
  registration_output=$(<"$registration_log")
  printf '%s\n' "$registration_output"
  report_registration_result "$TOKEN" "$registration_output" "$registration_rc" || exit 1
  TOKEN=

  find "$RUNNER_DIR" -maxdepth 1 -type f \
    \( -name '.credentials*' -o -name '.runner' \) -exec chmod 0600 {} +
  printf 'repository=%s\nname=%s\nlabel=%s\nbootstrap_version=%s\n' \
    "$RUNNER_REPOSITORY" "$RUNNER_NAME" "$RUNNER_LABEL" "$RUNNER_VERSION" \
    >"$INSTALL_MARKER"
  chown "$RUNNER_USER:$RUNNER_USER" "$INSTALL_MARKER"
  chmod 0600 "$INSTALL_MARKER"

  install_service
  printf 'fm-ci-runner-install.sh: installed water-7 under dedicated user %s\n' "$RUNNER_USER"
  printf 'verify: systemctl status %s\n' "$(service_name)"
  printf 'verify: reboot, then systemctl is-enabled %s && systemctl is-active %s\n' \
    "$(service_name)" "$(service_name)"
}

uninstall_runner() {
  local service=
  require_root
  validate_repository
  read_token

  if [ ! -d "$RUNNER_DIR" ]; then
    TOKEN=
    printf 'fm-ci-runner-install.sh: water-7 is already absent\n'
    return
  fi
  if service=$(service_name); then
    systemctl disable --now "$service" || die "could not stop water-7 service"
    (cd "$RUNNER_DIR" && ./svc.sh uninstall) || die "official service uninstall failed"
  fi
  if [ -f "$RUNNER_DIR/.runner" ]; then
    # shellcheck disable=SC2016 # Positional parameters expand in the child shell.
    runuser -u "$RUNNER_USER" -- bash -c '
      cd "$1"
      exec ./config.sh remove --token "$2"
    ' _ "$RUNNER_DIR" "$TOKEN" || die "GitHub runner removal failed; local credentials were preserved"
  fi
  TOKEN=
  find "$RUNNER_DIR" -mindepth 1 -depth -delete
  rmdir "$RUNNER_DIR"
  if id "$RUNNER_USER" >/dev/null 2>&1; then
    userdel --remove "$RUNNER_USER"
  fi
  if getent group "$RUNNER_GROUP" >/dev/null 2>&1; then
    groupdel "$RUNNER_GROUP"
  fi
  printf 'fm-ci-runner-install.sh: removed water-7 service, credentials, directory, and dedicated user\n'
}

status_runner() {
  local account account_home account_shell service
  printf 'repository=%s\nname=%s\nlabel=%s\nuser=%s\ndirectory=%s\n' \
    "$RUNNER_REPOSITORY" "$RUNNER_NAME" "$RUNNER_LABEL" "$RUNNER_USER" "$RUNNER_DIR"
  if account=$(getent passwd "$RUNNER_USER" 2>/dev/null); then
    account_home=$(printf '%s\n' "$account" | awk -F: '{print $6}')
    account_shell=$(printf '%s\n' "$account" | awk -F: '{print $7}')
    printf 'account_home=%s\naccount_shell=%s\naccount_groups=%s\n' \
      "$account_home" "$account_shell" "$(id -Gn "$RUNNER_USER")"
  else
    printf 'account=absent\n'
  fi
  if service=$(service_name); then
    printf 'service=%s\n' "$service"
    systemctl is-enabled "$service" || true
    systemctl is-active "$service" || true
  else
    printf 'service=absent\n'
  fi
}

ACTION=${1:-}
case "$ACTION" in
  --help|-h)
    usage
    exit 0
    ;;
  install|uninstall|diagnose-registration)
    shift
    ;;
  status)
    [ "$#" -eq 1 ] || die "status accepts no options"
    status_runner
    exit 0
    ;;
  dependencies)
    [ "$#" -eq 1 ] || die "dependencies accepts no options"
    print_missing_packages
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

REPOSITORY=$RUNNER_REPOSITORY
TOKEN_STDIN=0
TOKEN=
RUNNER_EXIT=
RUNNER_OUTPUT=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repository)
      [ "$#" -ge 2 ] || die "--repository needs OWNER/REPO"
      REPOSITORY=$2
      shift 2
      ;;
    --token-stdin)
      TOKEN_STDIN=1
      shift
      ;;
    --runner-exit)
      [ "$#" -ge 2 ] || die "--runner-exit needs a value"
      RUNNER_EXIT=$2
      shift 2
      ;;
    --runner-output)
      [ "$#" -ge 2 ] || die "--runner-output needs a path"
      RUNNER_OUTPUT=$2
      shift 2
      ;;
    *) die "unknown option: $1" ;;
  esac
done

case "$ACTION" in
  install) install_runner ;;
  uninstall) uninstall_runner ;;
  diagnose-registration) diagnose_registration ;;
esac
