#!/usr/bin/env bash
# Poll the ntfy kick topic and write the latest message to state/cloud-kick.md.
#
# Usage:
#   fm-cloud-holen.sh once     one blocking poll; print kick ok when a message lands
#   fm-cloud-holen.sh run      loop forever (default)
#
# Requires state/bruecke.env with BRUECKE_KICK. Announces a new kick through
# bin/fm-cloud-annahme.sh so firstmate sees it without waiting for captain chat.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-cloud-lib.sh
. "$SCRIPT_DIR/fm-cloud-lib.sh"

die() { printf 'fm-cloud-holen: %s\n' "$*" >&2; exit 1; }

poll_once() {
  local dest="$CLOUD_KICK_FILE" wrote=0
  fm_cloud_bruecke_configured || die "missing $CLOUD_BRUECKE_ENV"
  fm_cloud_load_bruecke
  [ -n "${BRUECKE_KICK:-}" ] || die 'BRUECKE_KICK is unset'
  export DEST="$dest"
  if curl -sS "https://ntfy.sh/${BRUECKE_KICK}/json?poll=1&since=all" | python3 -c 'import json,os,sys,tempfile
dest=os.environ["DEST"]
body=None
for line in sys.stdin:
    line=line.strip()
    if not line:
        continue
    try:
        o=json.loads(line)
    except json.JSONDecodeError:
        continue
    if o.get("event")=="message" and o.get("message"):
        body=o["message"]
if not body:
    sys.exit(1)
text=body if body.endswith("\n") else body+"\n"
fd,tmp=tempfile.mkstemp(dir=os.path.dirname(dest) or ".", prefix=".cloud-kick.", suffix=".tmp")
os.close(fd)
with open(tmp,"w",encoding="utf-8") as f:
    f.write(text)
os.replace(tmp, dest)
print("kick ok")'; then
    wrote=1
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_ROOT_OVERRIDE="$FM_ROOT" \
      "$SCRIPT_DIR/fm-cloud-annahme.sh" >/dev/null || true
  fi
  return $((1 - wrote))
}

cmd=${1:-run}
case "$cmd" in
  once)
    poll_once
    ;;
  run)
    while true; do
      poll_once || true
      sleep 5
    done
    ;;
  --help|-h)
    sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    ;;
  *)
    die "usage: $(basename "$0") [once|run]"
    ;;
esac
