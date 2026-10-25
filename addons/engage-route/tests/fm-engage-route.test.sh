#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
FM_HOME=$TMP/home
mkdir -p "$FM_HOME"/{bin,state,config}
cat > "$FM_HOME/bin/fm-task-inbox-lib.sh" <<'SH'
fm_task_inbox_write_idempotent() {
  local state=$1 task=$2 body=$3 dir="$1/$2.inbox" file
  mkdir -p "$dir"
  file="$dir/$(printf '%s' "$body" | sha256sum | cut -c1-16).msg"
  for existing in "$dir"/*.msg "$dir/handled"/*.msg; do
    [ -f "$existing" ] || continue
    [ "$(fm_task_inbox_body "$existing")" != "$body" ] || { printf '%s' "$existing"; return; }
  done
  printf 'schema=fm-task-inbox.v1\n--\n%s' "$body" > "$file"
  printf '%s' "$file"
}
fm_task_inbox_body() { awk 'found { print } $0 == "--" { found=1 }' "$1"; }
fm_backend_of_meta() { echo fixture; }
fm_backend_target_of_meta() { echo fixture-target; }
fm_task_inbox_ring() { return 0; }
SH
cat > "$TMP/signoff" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALL_LOG"
if [ "$1" = answers ]; then exit 99; fi
if [ "$1" = list ]; then
  printf '{"decisions":[{"key":"a","filer":"task-a"},{"key":"b","filer":"task-b"},{"key":"z","filer":"missing"},{"key":"f","filer":"finished"},{"key":"alt","filer":"alias"}]}'
else
  case " $* " in
    *' task-a '*) printf '{"deeper":[{"id":"req-a","key":"a","part":"intro","q":"A"}]}' ;;
    *' task-b '*) printf '{"deeper":[{"id":"req-b","key":"b","part":"intro","q":"B"}]}' ;;
    *' alias '*) printf '{"deeper":[{"id":"req-alt","key":"alt","part":"intro","q":"Override"}]}' ;;
    *' missing '*) printf '{"deeper":[{"id":"req-z","key":"z","part":"intro","q":"Z"}]}' ;;
    *) printf '{"deeper":[{"id":"req-f","key":"f","part":"intro","q":"F"}]}' ;;
  esac
fi
SH
chmod +x "$TMP/signoff"
printf 'kind=ship\n' > "$FM_HOME/state/task-a.meta"
printf 'kind=ship\n' > "$FM_HOME/state/task-b.meta"
printf 'kind=ship\n' > "$FM_HOME/state/finished.meta"
printf 'done [at=1]: finished\n' > "$FM_HOME/state/finished.status"
export FM_HOME SIGN_OFF_CLI="$TMP/signoff" FM_STATE_OVERRIDE="$FM_HOME/state" FM_CONFIG_OVERRIDE="$FM_HOME/config" CALL_LOG="$TMP/calls"
: > "$TMP/board.json"
"$ROOT/bin/fm-engage-route.sh" bind alias task-b
"$ROOT/bin/fm-engage-route.sh" dispatch "$TMP/board.json"
grep -q req-a "$FM_HOME/state/task-a.inbox/"*.msg
grep -q req-b "$FM_HOME/state/task-b.inbox/"*.msg
grep -q req-alt "$FM_HOME/state/task-b.inbox/"*.msg
[ ! -f "$FM_HOME/state/missing.inbox/request" ]
[ ! -f "$FM_HOME/state/finished.inbox/request" ]
grep -q $'req-f\tqueued\towner task finished is finished' "$FM_HOME/state/engage-route.log"
grep -q $'req-z\tqueued\tno owner record for filer missing' "$FM_HOME/state/engage-route.log"
if grep -q '^answers ' "$CALL_LOG"; then exit 1; fi
"$ROOT/bin/fm-engage-route.sh" dispatch "$TMP/board.json"
[ "$(find "$FM_HOME/state/task-a.inbox" -type f -name '*.msg' | wc -l)" -eq 1 ]
[ "$(find "$FM_HOME/state/task-b.inbox" -type f -name '*.msg' | wc -l)" -eq 2 ]
mkdir -p "$FM_HOME/state/task-a.inbox/handled"
first=$(find "$FM_HOME/state/task-a.inbox" -maxdepth 1 -name '*.msg' -print -quit)
mv "$first" "$FM_HOME/state/task-a.inbox/handled/"
"$ROOT/bin/fm-engage-route.sh" dispatch "$TMP/board.json"
grep -Fq $'req-a\towner-ack\ttask-a' "$FM_HOME/state/engage-route.log"
[ "$(find "$FM_HOME/state/task-a.inbox" -type f -name '*.msg' | wc -l)" -eq 1 ]
[ "$(awk -F '\t' '$1=="alias" {print $2}' "$FM_HOME/config/engage-owners")" = task-b ]
echo 'engage-route fixture journey passed'
