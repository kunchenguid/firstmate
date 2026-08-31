#!/usr/bin/env bash
set -u

sha256_stream() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}

sha256_file() {
  sha256_stream < "$1"
}

canonical_file() {
  jq -cS . "$1"
}

private_json() {
  local path=$1 value=$2 temporary
  mkdir -p "$(dirname "$path")"
  temporary="$(dirname "$path")/.$(basename "$path").tmp-$$"
  umask 077
  printf '%s\n' "$value" | jq -cS . > "$temporary" || return 1
  chmod 600 "$temporary"
  mv "$temporary" "$path"
}

vault_identity() {
  local vault=$1 values device inode
  if values=$(stat -c '%d %i' "$vault" 2>/dev/null); then
    :
  else
    values=$(stat -f '%d %i' "$vault") || return 1
  fi
  device=${values%% *}
  inode=${values##* }
  jq -nc --argjson device "$device" --argjson inode "$inode" --arg path "$vault" '{device:$device,inode:$inode,path:$path}'
}

inspect_plan() {
  local bundle_path=$1 vault=$2 bundle bundle_sha identity approval changed hashes modes
  jq -e '
    . as $bundle |
    $bundle.schema == "claude-obsidian.transaction.v1" and
    $bundle.operation_type == "save" and
    ($bundle.writes | type == "array" and length > 0) and
    ($bundle.expected_hashes | type == "object") and
    all($bundle.writes[]; . as $write |
      ($write.path | type == "string" and startswith("wiki/") and (split("/") | all(. != "" and . != "." and . != ".."))) and
      ($write.mode == "create" or $write.mode == "replace") and
      ($write.content | type == "string") and
      ($bundle.expected_hashes | has($write.path)) and
      (if $write.mode == "create" then $bundle.expected_hashes[$write.path] == null else ($bundle.expected_hashes[$write.path] | type == "string") end)
    )' "$bundle_path" >/dev/null || return 2
  bundle=$(canonical_file "$bundle_path") || return 2
  bundle_sha=$(printf '%s' "$bundle" | sha256_stream) || return 2
  identity=$(vault_identity "$vault") || return 2
  approval=$(jq -ncS --argjson bundle "$bundle" --argjson vault_identity "$identity" '{bundle:$bundle,vault_identity:$vault_identity}' | sha256_stream) || return 2
  changed=$(printf '%s' "$bundle" | jq -c '[.writes[].path]') || return 2
  hashes=$(printf '%s' "$bundle" | jq -r '.writes[].path' | while IFS= read -r path; do
    printf '%s\t' "$path"
    printf '%s' "$bundle" | jq -j --arg path "$path" '.writes[] | select(.path==$path) | .content' | sha256_stream
  done | jq -Rsc 'split("\n") | map(select(length>0) | split("\t")) | map({key:.[0],value:.[1]}) | from_entries') || return 2
  modes=$(printf '%s' "$bundle" | jq -c '[.writes[] | {key:.path,value:420}] | from_entries') || return 2
  jq -ncS \
    --arg operation_id "$(printf '%s' "$bundle" | jq -r .operation_id)" \
    --arg operation_type "$(printf '%s' "$bundle" | jq -r .operation_type)" \
    --argjson changed_paths "$changed" \
    --argjson hashes "$hashes" \
    --argjson modes "$modes" \
    --arg bundle_sha "$bundle_sha" \
    --argjson identity "$identity" \
    --arg approval "$approval" \
    '{schema:"claude-obsidian.transaction-plan.v1",operation_id:$operation_id,operation_type:$operation_type,valid:true,changed_paths:$changed_paths,hashes:$hashes,modes:$modes,input_bundle_sha256:$bundle_sha,expanded_bundle_sha256:$bundle_sha,vault_identity:$identity,approval_sha256:$approval}'
}

rollback() {
  local bundle=$1 vault=$2 operation=$3 journal=$4 count=$5 index path target
  index=$count
  while [ "$index" -gt 0 ]; do
    index=$((index - 1))
    path=$(printf '%s' "$bundle" | jq -r --argjson index "$index" '.writes[$index].path')
    target="$vault/$path"
    if [ -f "$operation/.rollback/$index.data" ]; then
      mkdir -p "$(dirname "$target")"
      cp "$operation/.rollback/$index.data" "$target"
      chmod "$(cat "$operation/.rollback/$index.mode")" "$target"
    else
      rm -f "$target"
    fi
  done
  journal=$(printf '%s' "$journal" | jq -c '.state="rolled-back"')
  private_json "$operation/journal.json" "$journal"
}

apply_bundle() {
  local bundle_path=$1 vault=$2 approval=$3 plan bundle bundle_sha operation_id operation result_path lock
  local path target expected actual journal result index count applied hashes modes
  plan=$(inspect_plan "$bundle_path" "$vault") || return 2
  [ "$(printf '%s' "$plan" | jq -r .approval_sha256)" = "$approval" ] || return 2
  bundle=$(canonical_file "$bundle_path") || return 2
  bundle_sha=$(printf '%s' "$plan" | jq -r .input_bundle_sha256)
  operation_id=$(printf '%s' "$bundle" | jq -r .operation_id)
  operation="$vault/.vault-meta/transactions/$operation_id"
  result_path="$operation/changed-paths.json"
  if [ -f "$result_path" ]; then
    [ "$(jq -r .bundle_sha256 "$result_path")" = "$bundle_sha" ] || return 75
    if [ "$(jq -r .state "$operation/journal.json")" != complete ]; then
      jq -e --arg operation "$operation_id" --arg bundle "$bundle_sha" --arg approval "$approval" '
        .operation_id==$operation and .operation_type=="save" and .input_bundle_sha256==$bundle and .expanded_bundle_sha256==$bundle and .approval_sha256==$approval
      ' "$operation/journal.json" >/dev/null || return 2
      journal=$(jq -c '.state="complete"' "$operation/journal.json") || return 2
      private_json "$operation/journal.json" "$journal" || return 2
    fi
    jq -cS . "$result_path"
    return
  fi
  if [ -n "${FM_FIXTURE_APPLY_PAUSE_MARKER:-}" ]; then
    printf 'paused\n' > "$FM_FIXTURE_APPLY_PAUSE_MARKER"
    while [ ! -e "${FM_FIXTURE_APPLY_PAUSE_RELEASE:?}" ]; do
      sleep 0.01
    done
  fi
  mkdir -p "$vault/.vault-meta"
  lock="$vault/.vault-meta/mutation.lock"
  (set -C; umask 077; : > "$lock") 2>/dev/null || return 75
  count=$(printf '%s' "$bundle" | jq '.writes | length')
  index=0
  while [ "$index" -lt "$count" ]; do
    path=$(printf '%s' "$bundle" | jq -r --argjson index "$index" '.writes[$index].path')
    target="$vault/$path"
    expected=$(printf '%s' "$bundle" | jq -r --arg path "$path" '.expected_hashes[$path]')
    if [ -f "$target" ]; then
      actual=$(sha256_file "$target")
    else
      actual=null
    fi
    if [ "$actual" != "$expected" ]; then
      rm -f "$lock"
      return 75
    fi
    index=$((index + 1))
  done
  mkdir -p "$operation/.rollback"
  chmod 700 "$operation" "$operation/.rollback"
  journal=$(jq -ncS --arg operation_id "$operation_id" --arg bundle_sha "$bundle_sha" --arg approval "$approval" '{schema:"claude-obsidian.transaction-journal.v1",operation_id:$operation_id,operation_type:"save",input_bundle_sha256:$bundle_sha,expanded_bundle_sha256:$bundle_sha,approval_sha256:$approval,state:"applying",writes:[],applied:[]}')
  private_json "$operation/journal.json" "$journal" || { rm -f "$lock"; return 2; }
  index=0
  applied=0
  while [ "$index" -lt "$count" ]; do
    path=$(printf '%s' "$bundle" | jq -r --argjson index "$index" '.writes[$index].path')
    target="$vault/$path"
    if [ -f "$target" ]; then
      cp "$target" "$operation/.rollback/$index.data"
      if stat -c '%a' "$target" > "$operation/.rollback/$index.mode" 2>/dev/null; then
        :
      else
        stat -f '%Lp' "$target" > "$operation/.rollback/$index.mode"
      fi
    fi
    mkdir -p "$(dirname "$target")"
    printf '%s' "$bundle" | jq -j --argjson index "$index" '.writes[$index].content' > "$target" || {
      rollback "$bundle" "$vault" "$operation" "$journal" "$applied"
      rm -f "$lock"
      return 2
    }
    chmod 644 "$target"
    applied=$((applied + 1))
    journal=$(printf '%s' "$journal" | jq -c --arg path "$path" '.writes += [{path:$path}] | .applied += [$path]')
    private_json "$operation/journal.json" "$journal" || {
      rollback "$bundle" "$vault" "$operation" "$journal" "$applied"
      rm -f "$lock"
      return 2
    }
    if [ "${FM_FIXTURE_FAIL_AFTER:-}" = "$applied" ]; then
      rollback "$bundle" "$vault" "$operation" "$journal" "$applied"
      rm -f "$lock"
      return 2
    fi
    index=$((index + 1))
  done
  hashes=$(printf '%s' "$plan" | jq -c .hashes)
  modes=$(printf '%s' "$plan" | jq -c .modes)
  result=$(jq -ncS --arg operation_id "$operation_id" --arg bundle_sha "$bundle_sha" --arg approval "$approval" --argjson paths "$(printf '%s' "$plan" | jq -c .changed_paths)" --argjson hashes "$hashes" --argjson modes "$modes" '{schema:"claude-obsidian.transaction-result.v1",operation_id:$operation_id,operation_type:"save",bundle_sha256:$bundle_sha,expanded_bundle_sha256:$bundle_sha,approval_sha256:$approval,status:"complete",changed_paths:$paths,hashes:$hashes,modes:$modes}')
  private_json "$result_path" "$result" || {
    rollback "$bundle" "$vault" "$operation" "$journal" "$applied"
    rm -f "$lock"
    return 2
  }
  journal=$(printf '%s' "$journal" | jq -c '.state="complete"')
  private_json "$operation/journal.json" "$journal" || { rm -f "$lock"; return 2; }
  rm -rf "$operation/.rollback"
  rm -f "$lock"
  printf '%s\n' "$result"
}

[ "$#" -ge 5 ] && [ "$1" = transaction ] || exit 2
action=$2
bundle_path=$3
shift 3
vault=
approval=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --vault) vault=$2; shift 2 ;;
    --approved-plan-sha256) approval=$2; shift 2 ;;
    *) exit 2 ;;
  esac
done
[ -d "$vault" ] || exit 2
vault=$(cd "$vault" && pwd -P) || exit 2
case "$action" in
  inspect) inspect_plan "$bundle_path" "$vault" || exit $? ;;
  apply) [ -n "$approval" ] || exit 2; apply_bundle "$bundle_path" "$vault" "$approval" || exit $? ;;
  *) exit 2 ;;
esac
