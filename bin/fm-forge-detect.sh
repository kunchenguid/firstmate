#!/usr/bin/env bash
# Propose a clone's forge binding from its origin remote, for project-add intake.
# Prints exactly one line to stdout:
#   forge=gerrit evidence=<the protocol fact that suggests it>
#   forge=gitlab evidence=<the host fact that suggests it>
#   forge=none
# and exits 0 either way; a missing clone or a directory that is not a git work
# tree exits 2 with an error on stderr.
#
# PROPOSAL ONLY. This never writes the registry and no use-time path calls it:
# the captain's confirmation at intake is what binds the forge, and
# data/projects.md holds that answer as `forge=gerrit` or `forge=gitlab`, which
# bin/fm-project-mode.sh owns (docs/gerrit-forge-integration.md section 3).
# A confirmed record exists because detection can be wrong, so nothing re-derives
# the binding from the clone later.
#
# Evidence read, all local and never from the network; Gerrit's protocol facts
# are checked first because they are the stronger evidence:
#   - an origin fetch or push URL on SSH port 29418, Gerrit's default SSH port;
#   - an origin push refspec targeting refs/for/, Gerrit's change-creating ref;
#   - an origin host that is gitlab.com or has a DNS label exactly `gitlab`,
#     such as gitlab.example.com;
#   - an origin host that glab's own config file lists under `hosts:`, which
#     means this machine's glab was set up for that host. The file is
#     $GLAB_CONFIG_DIR/config.yml, or ${XDG_CONFIG_HOME:-~/.config}/glab-cli/config.yml.
# Anything else proposes none. A Gerrit server on a non-default port behind an
# HTTPS remote carries no Gerrit fact, and glab's config is one machine's
# opinion rather than a project fact, which is why the captain is asked rather
# than told.
# Usage: fm-forge-detect.sh <clone-dir>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-forge-host-lib.sh
. "$SCRIPT_DIR/fm-forge-host-lib.sh"

DIR=${1:?usage: fm-forge-detect.sh <clone-dir>}
if [ ! -d "$DIR" ] || ! git -C "$DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "error: $DIR is not a git work tree" >&2
  exit 2
fi

urls=$( { git -C "$DIR" config --get-all remote.origin.url || true
  git -C "$DIR" config --get-all remote.origin.pushurl || true; } 2>/dev/null)
while IFS= read -r url; do
  [ -n "$url" ] || continue
  case "$url" in
    ssh://*)
      authority=${url#ssh://}
      authority=${authority%%/*}
      case "$authority" in
        *:29418)
          host=${authority##*@}
          host=${host%:29418}
          printf 'forge=gerrit evidence=origin host %s uses SSH port 29418\n' "$host"
          exit 0
          ;;
      esac
      ;;
  esac
done <<EOF
$urls
EOF


refspecs=$(git -C "$DIR" config --get-all remote.origin.push 2>/dev/null || true)
while IFS= read -r refspec; do
  case "$refspec" in
    *:refs/for/*)
      printf 'forge=gerrit evidence=origin push refspec targets refs/for/\n'
      exit 0
      ;;
  esac
done <<EOF
$refspecs
EOF

glab_config=$(fm_forge_glab_config_file)
while IFS= read -r url; do
  [ -n "$url" ] || continue
  host=$(fm_forge_origin_host "$url" gitlab) || continue
  case ".$host." in
    .gitlab.com.|*.gitlab.*)
      printf 'forge=gitlab evidence=origin host %s names GitLab\n' "$host"
      exit 0
      ;;
  esac
  if fm_forge_glab_config_lists_host "$glab_config" "$host"; then
    printf 'forge=gitlab evidence=origin host %s is configured in glab (%s)\n' "$host" "$glab_config"
    exit 0
  fi
done <<EOF
$urls
EOF

printf 'forge=none\n'
