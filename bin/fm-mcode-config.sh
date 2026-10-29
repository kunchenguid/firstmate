#!/usr/bin/env bash
# Read-only launch preflight for a MiniMax Code (`mcode`) worker: proves the
# captain's own mcode configuration lets an unattended worker run, and that a
# requested model id is one mcode will actually use.
#
# Usage: fm-mcode-config.sh preflight [<provider/model>]
# Exit 0 when the launch may proceed, printing on stdout the one absolute mcode
# data directory it checked; exit 1 with the exact fix on stderr otherwise.
# bin/fm-spawn.sh pins MINIMAX_DATA_DIR to that printed directory in the
# worker's launch environment, so the worker reads exactly the configuration
# checked here; bin/fm-control.sh runs the same check before a relaunch stops
# the running worker.
#
# WHY THIS EXISTS. mcode 0.7.1's interactive TUI has no permission flag: its
# permission mode is only the top-level `permissionMode` key of
# <data dir>/config.yaml, and both `/permission full` and Alt+M write that
# global key. In the default `auto` mode a worker stops on an `Approval
# required` box for any write outside its workspace, which every Firstmate
# status append is. Relocating the data directory per task relocates the
# sign-in too. So the captain sets Full access (`permissionMode:
# bypassPermissions`) once, and this check refuses a launch until that is true;
# Firstmate never writes the key.
#
# The data directory is resolved the way mcode resolves it (MINIMAX_DATA_DIR,
# then MAVIS_DATA_DIR, each trimmed, else ~/.minimax), and a relative override
# is refused because the worker would resolve it against its own working
# directory, not this one.
#
# mcode also silently falls back to its default model when `-m` names an id it
# does not know (verified live: `-m minimax/MiniMax-Bogus-9` ran on
# M3.1-Flash), so a requested `<provider>/<model>` must name a provider block
# under `provider:` in the same file and, when that block lists `models`, one
# of its keys. A provider whose block lists no block-style models mapping
# launches unvalidated with a notice.
set -u

case "${1:-}" in
  -h|--help)
    sed -n '2,/^set -u/{ /^#/s/^# \{0,1\}//p; }' "$0"
    exit 0
    ;;
  preflight) ;;
  *)
    echo "usage: fm-mcode-config.sh preflight [<provider/model>]" >&2
    exit 2
    ;;
esac
MODEL=${2:-}

trim() { local v=$1; v=${v#"${v%%[![:space:]]*}"}; printf '%s' "${v%"${v##*[![:space:]]}"}"; }
DATA_DIR=$(trim "${MINIMAX_DATA_DIR:-}")
[ -n "$DATA_DIR" ] || DATA_DIR=$(trim "${MAVIS_DATA_DIR:-}")
[ -n "$DATA_DIR" ] || DATA_DIR=$HOME/.minimax
case "$DATA_DIR" in
  /*) ;;
  *)
    echo "error: the MiniMax Code data directory '$DATA_DIR' is relative, so the worker would resolve it against its own working directory instead of this one. Set MINIMAX_DATA_DIR to an absolute path, then retry." >&2
    exit 1
    ;;
esac
CONFIG=$DATA_DIR/config.yaml

if [ ! -r "$CONFIG" ]; then
  echo "error: MiniMax Code config $CONFIG is not readable, so its permission mode cannot be proven Full access. Run mcode once and choose Full access with /permission full, then retry." >&2
  exit 1
fi

# Top-level scalar, optionally quoted or followed by a comment; a later
# duplicate wins as in YAML loaders.
mode=$(awk '
  /^permissionMode[[:space:]]*:/ {
    v = $0
    sub(/^permissionMode[[:space:]]*:[[:space:]]*/, "", v)
    sub(/[[:space:]]+#.*$/, "", v)
    sub(/[[:space:]]+$/, "", v)
    if (v ~ /^".*"$/ || v ~ /^\047.*\047$/) v = substr(v, 2, length(v) - 2)
    mode = v
  }
  END { print mode }
' "$CONFIG")
if [ "$mode" != bypassPermissions ]; then
  echo "error: MiniMax Code is not in Full access (permissionMode is '${mode:-auto (unset)}' in $CONFIG), so an unattended worker would stop on its first approval prompt. Run \`/permission full\` in any mcode session, then retry." >&2
  exit 1
fi

if [ -n "$MODEL" ] && [ "$MODEL" != default ]; then
  case "$MODEL" in
    */*) ;;
    *)
      echo "error: MiniMax Code model '$MODEL' must be <provider>/<model>, for example minimax/MiniMax-M3.1-Flash" >&2
      exit 1
      ;;
  esac
  provider=${MODEL%%/*}
  model_id=${MODEL#*/}
  # Walk the block mapping by indentation, whatever its width: `provider:` at
  # column 0, its provider keys at the first deeper indentation, each
  # provider's own keys one level deeper still, and `models:` keys below that.
  # Prints `provider <name>` per provider, `models <name>` when that provider
  # has a block models mapping, and `model <name> <id>` per model key.
  listing=$(awk '
    function indent(s) { match(s, /^ */); return RLENGTH }
    function key(s,   k) {
      k = s
      sub(/^ */, "", k)
      if (k !~ /^("[^"]*"|\047[^\047]*\047|[^:#]+)[[:space:]]*:([[:space:]]|$)/) return ""
      if (k ~ /^"/) { k = substr(k, 2); sub(/".*$/, "", k) }
      else if (k ~ /^\047/) { k = substr(k, 2); sub(/\047.*$/, "", k) }
      else { sub(/[[:space:]]*:.*$/, "", k) }
      return k
    }
    /^[[:space:]]*(#|$)/ { next }
    {
      d = indent($0); k = key($0)
      if (d == 0) { inprov = (k == "provider"); pd = -1; next }
      if (!inprov) next
      if (pd < 0) pd = d
      if (d <= pd) { prov = k; kd = -1; inmodels = 0; if (d == pd && k != "") print "provider " prov; next }
      if (kd < 0) kd = d
      if (d <= kd) { inmodels = (d == kd && k == "models" && $0 ~ /:[[:space:]]*(#.*)?$/); md = -1; if (inmodels) print "models " prov; next }
      if (!inmodels) next
      if (md < 0) md = d
      if (d == md && k != "") print "model " prov " " k
    }
  ' "$CONFIG")
  if ! printf '%s\n' "$listing" | grep -qxF "provider $provider"; then
    known=$(printf '%s\n' "$listing" | sed -n 's/^provider //p' | paste -sd, - | sed 's/,/, /g')
    echo "error: MiniMax Code provider '$provider' is not configured under provider: in $CONFIG (configured: ${known:-none}); mcode would silently run its default model instead. Choose a configured provider or omit --model." >&2
    exit 1
  fi
  if ! printf '%s\n' "$listing" | grep -qxF "models $provider"; then
    echo "notice: MiniMax Code provider '$provider' lists no models mapping in $CONFIG; launching with -m '$MODEL' unvalidated" >&2
  elif ! printf '%s\n' "$listing" | grep -qxF "model $provider $model_id"; then
    known=$(printf '%s\n' "$listing" | sed -n "s|^model $provider |$provider/|p" | paste -sd, - | sed 's/,/, /g')
    echo "error: MiniMax Code model '$MODEL' is not configured in $CONFIG (configured: ${known:-none}); mcode would silently run its default model instead. Choose a configured id or omit --model." >&2
    exit 1
  fi
fi
printf '%s\n' "$DATA_DIR"
