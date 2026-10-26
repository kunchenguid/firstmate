#!/usr/bin/env bash
# Wire one of the pinned companion tools Juggernaut publishes into this home.
# Usage: fm-tool-wiring.sh done-done|sign-off
#
# Idempotent: the second run writes nothing and prints nothing, so
# bin/fm-bootstrap.sh calls it on every locked session start.
# done-done  links the skill the pinned done-done-axi package ships, appends its
#            integrations/firstmate/brief-include.md to config/brief-include.md
#            as one managed block (a rerun replaces that block instead of
#            appending a duplicate), and places its
#            integrations/firstmate/merge-gate as config/merge-gate, executable.
#            The gate is placed only when this home has none, so a home that
#            chained another gate (owner-guard, owner-rules) keeps its chain.
# sign-off   links the skill the pinned sign-off-axi package ships and prints the
#            one-line arming reminder while this home is unarmed; arming itself
#            stays per home and is never done here.
#
# Nothing here installs a package - bin/fm-bootstrap.sh's install_cmd owns the
# pinned `npm install -g` line - and an absent npm or package is a silent no-op.
# A skill is linked into $HOME/.agents/skills and into each agent skills
# directory whose agent directory already exists, so no agent is invented and an
# existing skill entry is never replaced.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

INCLUDE_BEGIN='<!-- done-done brief include (managed by bin/fm-tool-wiring.sh) -->'
INCLUDE_END='<!-- end done-done brief include -->'

case "${1:-}" in
  done-done|sign-off) TOOL=$1 ;;
  *) echo "usage: fm-tool-wiring.sh done-done|sign-off" >&2; exit 2 ;;
esac

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

package_dir() {  # <npm-package-name>
  local root
  root=$(npm root -g 2>/dev/null) || return 1
  [ -n "$root" ] || return 1
  printf '%s\n' "$root/$1"
}

skill_dirs() {
  local rel
  for rel in .agents/skills .claude/skills .codex/skills .pi/agent/skills; do
    case $rel in
      .agents/skills) printf '%s\n' "$HOME/$rel" ;;
      *) [ -d "$HOME/${rel%/*}" ] && printf '%s\n' "$HOME/$rel" ;;
    esac
  done
}

install_skill() {  # <package-skill-dir> <skill-name>
  local src=$1 name=$2 dir dest rc=0
  [ -f "$src/SKILL.md" ] || return 1
  while IFS= read -r dir; do
    dest=$dir/$name
    [ -n "$dir" ] || continue
    if [ -e "$dest" ] || [ -L "$dest" ]; then
      continue
    fi
    if ! mkdir -p "$dir" || ! ln -s "$src" "$dest"; then
      rc=1
      continue
    fi
    LINKED=1
    printf 'linked %s -> %s\n' "$dest" "$src"
  done < <(skill_dirs)
  return "$rc"
}

write_include() {  # <package-dir>
  local block=$1/integrations/firstmate/brief-include.md dest=$CONFIG/brief-include.md tmp
  [ -r "$block" ] || return 1
  mkdir -p "$CONFIG" || return 1
  if [ -L "$dest" ] || { [ -e "$dest" ] && [ ! -f "$dest" ]; }; then
    printf 'error: %s is not a regular file\n' "$dest" >&2
    return 1
  fi
  if [ -f "$dest" ] && grep -qF "$INCLUDE_BEGIN" "$dest"; then
    grep -qF -- "$(cat "$block")" "$dest" && return 0
    tmp=$(mktemp "$CONFIG/.brief-include.XXXXXX") || return 1
    awk -v b="$INCLUDE_BEGIN" -v e="$INCLUDE_END" '
      $0 == b { skip = 1; next }
      skip && $0 == e { skip = 0; next }
      !skip { print }
    ' "$dest" > "$tmp" || { rm -f -- "$tmp"; return 1; }
    cat "$tmp" > "$dest" || { rm -f -- "$tmp"; return 1; }
    rm -f -- "$tmp"
  fi
  { printf '%s\n' "$INCLUDE_BEGIN"; cat "$block"; printf '%s\n' "$INCLUDE_END"; } >> "$dest" \
    || return 1
  printf 'wrote %s\n' "$dest"
}

place_gate() {  # <package-dir>
  local src=$1/integrations/firstmate/merge-gate dest=$CONFIG/merge-gate
  [ -r "$src" ] || return 1
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    return 0
  fi
  mkdir -p "$CONFIG" && cp -- "$src" "$dest" && chmod 700 "$dest" || return 1
  printf 'placed %s\n' "$dest"
}

LINKED=0
case $TOOL in
  done-done)
    pkg=$(package_dir done-done-axi) || exit 0
    [ -d "$pkg" ] || exit 0
    install_skill "$pkg/skills/done-done" done-done || die "done-done skill is not linked"
    write_include "$pkg" || die "done-done brief include is not written"
    place_gate "$pkg" || die "done-done merge gate is not placed"
    ;;
  sign-off)
    pkg=$(package_dir sign-off-axi) || exit 0
    [ -d "$pkg" ] || exit 0
    install_skill "$pkg/skills/sign-off-axi" sign-off-axi || die "sign-off skill is not linked"
    if [ "$LINKED" -eq 1 ] && [ ! -e "$STATE/procevent/signoff.source" ]; then
      printf '%s\n' 'sign-off is installed but this home is not armed, so captain holds raise no board card; arm it once with bin/fm-procevent-signoff.sh arm, and each secondmate home arms itself the same way'
    fi
    ;;
esac
exit 0
