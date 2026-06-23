#!/usr/bin/env bash
# Bootstrap detection, best-effort fleet refresh/prune, and installs.
# Usage: fm-bootstrap.sh
#          Detect: prints one line per problem and exits 0. Silent = all good.
#          Lines: "MISSING: <tool> (install: <command>)", "NEEDS_GH_AUTH",
#                 "CREW_HARNESS_OVERRIDE: <name>", "FLEET_SYNC: <repo>: skipped: <reason>".
#          treehouse is also MISSING when its installed version lacks
#          "treehouse get --lease" support or post_create hook support.
#          treehouse-post-create-hook is MISSING when Treehouse is not wired
#          to firstmate's global post_create hook.
#          Fleet sync fetches, fast-forwards, and prunes gone local branches;
#          it is bounded by FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT, default 20s.
#          Set FM_FLEET_PRUNE=0 to skip branch pruning during that refresh.
#        fm-bootstrap.sh install <tool>...
#          Install the named tools (only ones the captain approved).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

fleet_sync() {
  [ -x "$FM_ROOT/bin/fm-fleet-sync.sh" ] || return 0
  [ -d "$PROJECTS" ] || return 0

  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-fleet-sync.XXXXXX" 2>/dev/null) || return 0
  monitor_was_on=0
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m 2>/dev/null || true
  "$FM_ROOT/bin/fm-fleet-sync.sh" >"$tmp" 2>/dev/null &
  pid=$!

  timeout=${FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT:-20}
  case "$timeout" in ''|*[!0-9]*) timeout=20 ;; esac
  start=$SECONDS
  while jobs -r -p | grep -qx "$pid"; do
    if [ $((SECONDS - start)) -ge "$timeout" ]; then
      kill -TERM "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
      echo "FLEET_SYNC: fleet: skipped: bootstrap refresh timed out"
      rm -f "$tmp"
      return 0
    fi
    sleep 1
  done
  wait "$pid" 2>/dev/null || true
  [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true

  while IFS= read -r line; do
    case "$line" in
      *': skipped: local-only project') ;;
      *': skipped: no origin remote') ;;
      *': skipped:'*) echo "FLEET_SYNC: $line" ;;
    esac
  done < "$tmp"
  rm -f "$tmp"
}

install_cmd() {
  case "$1" in
    tmux|node|gh) echo "brew install $1  # or the platform's package manager" ;;
    treehouse) echo "curl -fsSL https://kunchenguid.github.io/treehouse/install.sh | sh" ;;
    treehouse-post-create-hook) printf '%q install treehouse-post-create-hook\n' "$FM_ROOT/bin/fm-bootstrap.sh" ;;
    no-mistakes) echo "curl -fsSL https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh | sh" ;;
    gh-axi|chrome-devtools-axi|lavish-axi) echo "npm install -g $1 && $1 setup hooks" ;;
    *) return 1 ;;
  esac
}

TOOLS="tmux node gh treehouse no-mistakes gh-axi chrome-devtools-axi lavish-axi"

treehouse_supports_lease() {
  treehouse get --help 2>&1 | grep -Eq '(^|[^[:alnum:]_-])--lease([^[:alnum:]_-]|$)'
}

treehouse_supports_post_create() {
  version=$(treehouse --version 2>/dev/null) || return 1
  version=${version#treehouse }
  version=${version#v}
  case "$version" in
    [0-9]*.[0-9]*.[0-9]*)
      major=${version%%.*}
      rest=${version#*.}
      minor=${rest%%.*}
      patch=${rest#*.}
      patch=${patch%%[!0-9]*}
      [ -n "$patch" ] || patch=0
      [ "$major" -gt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -gt 8 ]; } || { [ "$major" -eq 1 ] && [ "$minor" -eq 8 ] && [ "$patch" -ge 0 ]; }
      ;;
    *) return 1 ;;
  esac
}

treehouse_config_path() {
  printf '%s\n' "${TREEHOUSE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/treehouse/config.toml}"
}

treehouse_hook_path() {
  cd "$FM_ROOT/bin" 2>/dev/null && printf '%s/fm-treehouse-post-create.sh\n' "$(pwd -P)"
}

treehouse_post_create_hook_configured() {
  config=$(treehouse_config_path)
  hook=$(treehouse_hook_path) || return 1
  [ -f "$config" ] || return 1
  awk -v hook="$hook" '
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ { in_hooks = ($0 ~ /^[[:space:]]*\[hooks\][[:space:]]*$/); in_post_create = 0 }
    in_hooks && /^[[:space:]]*post_create[[:space:]]*=/ { in_post_create = 1 }
    in_hooks && in_post_create && index($0, hook) { found = 1 }
    in_hooks && in_post_create && /\]/ { in_post_create = 0 }
    END { exit found ? 0 : 1 }
  ' "$config"
}

treehouse_config_has_hooks_section() {
  grep -Eq '^[[:space:]]*\[hooks\][[:space:]]*$' "$1"
}

treehouse_config_has_post_create() {
  awk '
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ { in_hooks = ($0 ~ /^[[:space:]]*\[hooks\][[:space:]]*$/) }
    in_hooks && /^[[:space:]]*post_create[[:space:]]*=/ { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$1"
}

install_treehouse_hook() {
  config=$(treehouse_config_path)
  hook=$(treehouse_hook_path) || return 1
  if treehouse_post_create_hook_configured; then
    return 0
  fi
  mkdir -p "$(dirname "$config")"
  if [ ! -f "$config" ]; then
    printf '[hooks]\npost_create = ["%s"]\n' "$hook" >"$config"
    return 0
  fi
  if ! treehouse_config_has_hooks_section "$config"; then
    printf '\n[hooks]\npost_create = ["%s"]\n' "$hook" >>"$config"
    return 0
  fi
  if ! treehouse_config_has_post_create "$config"; then
    tmp=$(mktemp "${TMPDIR:-/tmp}/fm-treehouse-config.XXXXXX") || return 1
    if awk -v hook="$hook" '
      { print }
      !inserted && /^[[:space:]]*\[hooks\][[:space:]]*$/ {
        printf "post_create = [\"%s\"]\n", hook
        inserted = 1
      }
    ' "$config" >"$tmp" && mv "$tmp" "$config"; then
      rm -f "$tmp"
      return 0
    fi
    rm -f "$tmp"
    return 1
  fi
  echo "error: treehouse post_create is already configured without $hook; add it to $config" >&2
  return 1
}

if [ "${1:-}" = "install" ]; then
  shift
  [ $# -gt 0 ] || { echo "usage: fm-bootstrap.sh install <tool>..." >&2; exit 1; }
  for t in "$@"; do
    cmd=$(install_cmd "$t") || { echo "error: unknown tool $t" >&2; exit 1; }
    if [ "$t" = treehouse-post-create-hook ]; then
      echo "installing $t: $cmd"
      install_treehouse_hook || exit 1
      continue
    fi
    cmd=${cmd%%  #*}
    echo "installing $t: $cmd"
    eval "$cmd"
  done
  exit 0
fi

for t in $TOOLS; do
  command -v "$t" >/dev/null || echo "MISSING: $t (install: $(install_cmd "$t"))"
done
if command -v treehouse >/dev/null 2>&1 && { ! treehouse_supports_lease || ! treehouse_supports_post_create; }; then
  echo "MISSING: treehouse (install: $(install_cmd treehouse))"
fi
if command -v treehouse >/dev/null 2>&1 && treehouse_supports_lease && treehouse_supports_post_create && ! treehouse_post_create_hook_configured; then
  echo "MISSING: treehouse-post-create-hook (install: $(install_cmd treehouse-post-create-hook))"
fi
gh auth status >/dev/null 2>&1 || echo "NEEDS_GH_AUTH"
crew=
[ -f "$CONFIG/crew-harness" ] && crew=$(tr -d '[:space:]' < "$CONFIG/crew-harness" || true)
[ -n "$crew" ] && [ "$crew" != "default" ] && echo "CREW_HARNESS_OVERRIDE: $crew"
fleet_sync
exit 0
