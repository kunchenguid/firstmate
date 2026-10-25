#!/usr/bin/env bash
# fm-model-allowlist.sh - one allow-list per provider: view and edit it, refuse an
# off-list pick with one line, and watch for a model that started anyway.
#
# Usage:
#   fm-model-allowlist.sh                       every provider and its models
#   fm-model-allowlist.sh allow|deny <provider> <model>...
#   fm-model-allowlist.sh check <provider> <model>
#   fm-model-allowlist.sh watch                 the fleet check (silent when clean)
#   fm-model-allowlist.sh install|uninstall
#
# The list is config/model-allow-list.json, one key per provider
# ({"codex": ["gpt-5.6-sol"]}), the same file the firstmate-addons model-gate reads.
# docs/configuration.md "Model allow-lists" owns the key shape, the match rule, and
# the refusal wording; this file implements them for every launch.
#
# bin/fm-spawn.sh sources this file and refuses an off-list model on every launch,
# before any endpoint, local copy, or record exists, whichever source the model came
# from: a --model flag, a dispatch profile, or a config/crew-harness and
# config/secondmate-harness token. watch reports a model that started outside that
# gate, once each; install registers it for the watcher and uninstall retires it.
# Sourced, this file only defines functions.


# fm_model_allowlist_file: the list path, read at call time so a caller's own
# CONFIG or FM_HOME applies.
fm_model_allowlist_file() {
  local config=${FM_CONFIG_OVERRIDE:-${CONFIG:-${FM_HOME:-${FM_ROOT_OVERRIDE:-$HOME/firstmate}}/config}}
  printf '%s\n' "${FM_MODEL_ALLOWLIST:-$config/model-allow-list.json}"
}

# fm_model_allowlist_provider <harness> <model>: the key a model is listed under.
fm_model_allowlist_provider() {
  case $2 in
  */*) printf '%s\n' "${2%%/*}" ;;
  *) printf '%s\n' "$1" ;;
  esac
}

# fm_model_allowlist_verdict <provider> <model>: print "<verdict>\t<allowed words>",
# where verdict is allow, deny, or unreadable.
fm_model_allowlist_verdict() {
  local provider=$1 model=$2 list m out
  list=$(fm_model_allowlist_file)
  [ -e "$list" ] || { printf 'allow\tnone\n'; return 0; }
  m=$model
  case $m in "$provider"/*) m=${m#"$provider"/} ;; esac
  out=$(jq -r --arg p "$provider" --arg m "$m" --arg f "$list" '
    if type != "object" or any(.[]; type != "array" or (any(.[]; type != "string")))
    then "unreadable\t\($f) is not a readable JSON object of provider to [models]"
    elif (has($p) | not) then "allow\tnone"
    else (.[$p] | if length == 0 then "none" else join(", ") end) as $w
      | if ([.[$p][] as $e | $m == $e or ($m | startswith($e + ":"))] | any)
        then "allow\t\($w)" else "deny\t\($w)" end
    end' "$list" 2>/dev/null) || out=''
  [ -n "$out" ] || out=$(printf 'unreadable\t%s cannot be read (jq missing or invalid JSON)' "$list")
  printf '%s\n' "$out"
}

# fm_model_allowlist_require <harness> <model>: 0 when the pick may proceed, else
# the one refusal line on stderr and 1. An empty or `default` model names no
# provider and is never refused here.
fm_model_allowlist_require() {
  local provider=$1 model=$2 verdict words
  case $model in '' | default) return 0 ;; esac
  provider=$(fm_model_allowlist_provider "$1" "$model")
  model=${model#"$provider"/}
  IFS=$'\t' read -r verdict words <<<"$(fm_model_allowlist_verdict "$provider" "$model")"
  case $verdict in
  allow) return 0 ;;
  deny)
    printf 'error: %s model %s is not allowed (allowed: %s); allow it with bin/fm-model-allowlist.sh allow %s %s\n' \
      "$provider" "$model" "$words" "$provider" "$model" >&2
    ;;
  *) printf 'error: %s model %s is not checked, %s; fix or remove it, then retry\n' "$provider" "$model" "$words" >&2 ;;
  esac
  return 1
}

# --- the operator command; nothing below here runs when this file is sourced ---
[ "${BASH_SOURCE[0]}" -ef "$0" ] || return 0

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LIST=$(fm_model_allowlist_file)
SEEN="$STATE/.model-allowlist.seen"
CHECK_ID='model-allowlist'
CHECK="$STATE/$CHECK_ID.check.sh"

die() { printf 'fm-model-allowlist: %s\n' "$*" >&2; exit 2; }

show() {
  [ -e "$LIST" ] || { printf 'no allow-list at %s: every provider is unconstrained\n' "$LIST"; return 0; }
  jq -r 'to_entries[] | "\(.key): \(if (.value | length) == 0 then "none" else (.value | join(" ")) end)"' "$LIST" 2>/dev/null ||
    die "$LIST is not a JSON object of provider to [models]"

}

edit() { # <allow|deny> <provider> <model>...
  local mode=$1 provider=$2 current models
  shift 2
  [ "$#" -ge 1 ] || die "usage: fm-model-allowlist.sh $mode <provider> <model>..."
  mkdir -p -- "${LIST%/*}" || die "cannot create ${LIST%/*}"
  current=$(cat -- "$LIST" 2>/dev/null || true)
  [ -n "$current" ] || current='{}'
  models=$(printf '%s\n' "$@" | jq -R . | jq -s -c .) || die "cannot encode the model names"
  printf '%s' "$current" | jq --arg p "$provider" --argjson models "$models" --arg mode "$mode" \
    '.[$p] = (if $mode == "allow" then (((.[$p] // []) + $models) | unique) else ((.[$p] // []) - $models) end)' \
    >"$LIST.tmp-$$" || { rm -f -- "$LIST.tmp-$$"; die "cannot update $LIST"; }
  mv -f -- "$LIST.tmp-$$" "$LIST" || die "cannot replace $LIST"
  show
}

# The launches this home actually made, as "<harness>\t<model>" lines.
launches() {
  local history
  for history in "$STATE"/*.models; do
    [ -f "$history" ] || continue
    awk -F'\t' 'NF >= 3 && $3 != "" && $3 != "default" { printf "%s\t%s\n", $2, $3 }' "$history"
  done
}

watch() {
  local harness model provider verdict words previous current out
  previous=$(cat -- "$SEEN" 2>/dev/null || true)
  current=''
  out=''
  while IFS=$'\t' read -r harness model; do
    [ -n "$model" ] || continue
    provider=$(fm_model_allowlist_provider "$harness" "$model")
    IFS=$'\t' read -r verdict words <<<"$(fm_model_allowlist_verdict "$provider" "$model")"
    [ "$verdict" = deny ] || continue
    current+="$provider/$model"$'\n'
    printf '%s\n' "$previous" | grep -qxF -- "$provider/$model" && continue
    out+=$(printf 'model-allowlist: %s ran model %s although %s allows %s; allow it with bin/fm-model-allowlist.sh allow %s %s\n' \
      "$harness" "$model" "$provider" "$words" "$provider" "$model")$'\n'
  done < <(launches | sort -u)
  mkdir -p -- "$STATE" 2>/dev/null && printf '%s' "$current" >"$SEEN" 2>/dev/null
  [ -z "$out" ] || printf '%s' "$out"
}

install_check() {
  local tmp
  mkdir -p -- "$STATE" || die "cannot create $STATE"
  tmp=$(mktemp "$STATE/.model-allowlist.check.XXXXXX") || die "cannot write $CHECK"
  printf '#!/usr/bin/env bash\n# fleet check: off-list models this home ran (regenerate with install)\nexec %q watch\n' \
    "$SCRIPT_DIR/fm-model-allowlist.sh" >"$tmp" || { rm -f -- "$tmp"; die "cannot write $CHECK"; }
  chmod 700 "$tmp"
  mv -f -- "$tmp" "$CHECK" || die "cannot install $CHECK"
  "$SCRIPT_DIR/fm-check-register.sh" "$CHECK_ID" || die "cannot register $CHECK_ID"
}

case ${1:-list} in
list) show ;;
allow | deny) edit "$@" ;;
check) [ "$#" -eq 3 ] || die "usage: fm-model-allowlist.sh check <provider> <model>"; fm_model_allowlist_require "$2" "$3" ;;
watch) watch ;;
install) install_check ;;
uninstall)
  [ ! -x "$SCRIPT_DIR/fm-check-unregister.sh" ] ||
    "$SCRIPT_DIR/fm-check-unregister.sh" "$CHECK_ID" >/dev/null 2>&1 || true
  rm -f -- "$CHECK" "$SEEN"
  printf 'uninstalled: %s\n' "$CHECK_ID"
  ;;
*) die "unknown action: $1 (list, allow, deny, check, watch, install, uninstall)" ;;
esac
