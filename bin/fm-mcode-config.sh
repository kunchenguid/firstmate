#!/usr/bin/env bash
# Read-only launch preflight for a MiniMax Code (`mcode`) worker: proves the
# captain's own mcode configuration lets an unattended worker run, and that a
# requested model id is one mcode will actually use.
#
# Usage: fm-mcode-config.sh preflight [<provider/model>]
# Exit 0 when the launch may proceed (a notice on stderr when the model could
# not be checked); exit 1 with the exact fix on stderr otherwise.
#
# WHY THIS EXISTS. mcode 0.7.1's interactive TUI has no permission flag: its
# permission mode is only the top-level `permissionMode` key of
# $MINIMAX_DATA_DIR/config.yaml (default ~/.minimax/config.yaml), and both
# `/permission full` and Alt+M write that global key. In the default `auto`
# mode a worker stops on an `Approval required` box for any write outside its
# workspace, which every Firstmate status append is. Relocating
# MINIMAX_DATA_DIR per task relocates the sign-in too. So the captain sets Full
# access (`permissionMode: bypassPermissions`) once, and this check refuses a
# launch until that is true; Firstmate never writes the key.
#
# mcode also silently falls back to its default model when `-m` names an id it
# does not know (verified live: `-m minimax/MiniMax-Bogus-9` ran on
# M3.1-Flash), so a requested `<provider>/<model>` is checked against the
# `provider.<provider>.models` keys of the same file. When that provider block
# is absent (a provider configured elsewhere) or the file is unreadable, the
# model is reported unvalidated rather than refused, the agy precedent.
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

DATA_DIR=${MINIMAX_DATA_DIR:-}
[ -n "$DATA_DIR" ] || DATA_DIR=${MAVIS_DATA_DIR:-}
[ -n "$DATA_DIR" ] || DATA_DIR=$HOME/.minimax
CONFIG=$DATA_DIR/config.yaml

if [ ! -r "$CONFIG" ]; then
  echo "error: MiniMax Code config $CONFIG is not readable, so its permission mode cannot be proven Full access. Run mcode once and choose Full access with /permission full, then retry." >&2
  exit 1
fi

# Top-level scalar, optionally quoted; a later duplicate wins as in YAML loaders.
mode=$(awk '
  /^permissionMode:/ {
    v = $0
    sub(/^permissionMode:[[:space:]]*/, "", v)
    sub(/[[:space:]]+#.*$/, "", v)
    gsub(/^["\047]|["\047][[:space:]]*$/, "", v)
    sub(/[[:space:]]+$/, "", v)
    mode = v
  }
  END { print mode }
' "$CONFIG")
if [ "$mode" != bypassPermissions ]; then
  echo "error: MiniMax Code is not in Full access (permissionMode is '${mode:-auto (unset)}' in $CONFIG), so an unattended worker would stop on its first approval prompt. Run \`/permission full\` in any mcode session, then retry." >&2
  exit 1
fi

[ -n "$MODEL" ] && [ "$MODEL" != default ] || exit 0
case "$MODEL" in
  */*) ;;
  *)
    echo "error: MiniMax Code model '$MODEL' must be <provider>/<model>, for example minimax/MiniMax-M3.1-Flash" >&2
    exit 1
    ;;
esac
provider=${MODEL%%/*}
model_id=${MODEL#*/}

# Walk provider.<provider>.models.<id> by indentation. Prints `provider` when
# the provider block exists with a models mapping, then one `model <id>` line
# per configured id.
listing=$(awk -v prov="$provider" '
  function indent(s) { match(s, /^ */); return RLENGTH }
  function key(s,   k) {
    k = s
    sub(/^ */, "", k)
    if (k !~ /:/) return ""
    sub(/:.*$/, "", k)
    gsub(/^["\047]|["\047]$/, "", k)
    return k
  }
  /^[[:space:]]*(#|$)/ { next }
  {
    d = indent($0); k = key($0)
    if (d == 0) { inprov = (k == "provider"); inthis = 0; inmodels = 0; next }
    if (!inprov) next
    if (d <= 2) { inthis = (d == 2 && k == prov); inmodels = 0; next }
    if (!inthis) next
    if (d <= 4) {
      inmodels = (d == 4 && k == "models")
      if (inmodels) print "provider"
      next
    }
    if (inmodels && d == 6 && k != "") print "model " k
  }
' "$CONFIG")
if ! printf '%s\n' "$listing" | grep -qx provider; then
  echo "notice: MiniMax Code provider '$provider' has no models list in $CONFIG; launching with -m '$MODEL' unvalidated" >&2
  exit 0
fi
if ! printf '%s\n' "$listing" | grep -qxF "model $model_id"; then
  known=$(printf '%s\n' "$listing" | sed -n "s|^model |$provider/|p" | paste -sd, - | sed 's/,/, /g')
  echo "error: MiniMax Code model '$MODEL' is not configured in $CONFIG (configured: ${known:-none}); mcode would silently run its default model instead. Choose a configured id or omit --model." >&2
  exit 1
fi
exit 0
