#!/usr/bin/env bash
# Run OpenCode discovery inside the destination pane's launch environment.
# Only model-related config fields leave the debug-config process.
set -u

if [ "$#" -ne 5 ]; then
  echo "usage: fm-opencode-probe.sh <binary> <worktree> <result-dir> <timeout-seconds> <resolve-config:0|1>" >&2
  exit 2
fi

bin=$1
worktree=$2
result_dir=$3
bound=$4
resolve_config=$5
case "$bound" in ''|*[!0-9]*|0*) exit 2 ;; esac
case "$resolve_config" in 0|1) ;; *) exit 2 ;; esac
[ -x "$bin" ] && [ -d "$worktree" ] && [ -d "$result_dir" ] || exit 2

# Resolve this script's own directory BEFORE changing directory, from
# BASH_SOURCE rather than $0: fm-spawn invokes it with an absolute path, but a
# relative one would be resolved against the worktree it is about to enter.
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || exit 2
cd "$worktree" || exit 2
# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$script_dir/fm-timeout-lib.sh"

if [ "$resolve_config" = 1 ]; then
  if [ -n "${OPENCODE_CONFIG:-}" ] || [ -n "${OPENCODE_CONFIG_DIR:-}" ]; then
    printf '%s\n' 'config-location-override' > "$result_dir/config.reason"
    printf '78\n' > "$result_dir/config.status"
  else
  if [ -n "${XDG_CONFIG_HOME:-}" ]; then
    global_config="$XDG_CONFIG_HOME/opencode"
  elif [ -n "${HOME:-}" ]; then
    global_config="$HOME/.config/opencode"
  else
    printf '78\n' > "$result_dir/config.status"
  fi
  if [ ! -f "$result_dir/config.status" ]; then
    # shellcheck disable=SC2016  # single quotes are deliberate: $provider/$model and $global are jq's, not the shell's
    normalize_filter='
        def model_value:
          if type == "string" then .
          elif type == "object" then
            (.providerID // .provider) as $provider
            | (.model // .modelID) as $model
            | if ($provider | type) == "string" and ($model | type) == "string" then
                "\($provider)/\($model)" +
                (if (.variant | type) == "string" and .variant != "" then "#\(.variant)" else "" end)
              else null end
          else null end;
        # `opencode models` lists only base ids, never a "#variant" form, so the
        # only source that can confirm a selected variant is the provider
        # metadata in the resolved config. Both published shapes of that field
        # are normalized to the same list, because which one appears is a
        # property of the OpenCode version rather than a choice by the caller:
        #   array of objects  v2 - each entry carries its own `id`
        #   object keyed by id v1 - the variant id is the key
        # Any id that cannot be read as a string yields no entry at all, which
        # leaves the exact-match requirement in the caller unsatisfied and keeps
        # the launch closed.
        # Both the DECLARED ids and the SELECTABLE subset are kept, per config
        # document and keyed by base id, because a document that disables one
        # variant still DECLARES it while selecting none of it. A union across
        # documents would let a lower-precedence enabled variant survive a
        # higher-precedence disable, so the caller ranks these per document
        # rather than merging them here.
        def variant_entries:
          if type == "array" then [.[] | {id: .id, disabled: .disabled}]
          elif type == "object" then [to_entries[]
            | {id: .key, disabled: (.value | if type == "object" then .disabled else null end)}]
          else [] end;
        def variant_map:
          if type == "object" then
            [ (.providers // {} | to_entries[]) as $provider
              | ($provider.value.models // {} | to_entries[]) as $model
              | ($model.value.variants // {}) as $declared
              # `[]` iterates the normalized entries; without it `as $entry`
              # would bind the whole array and the field reads below would fail.
              | ($declared | variant_entries)[]
              | select((.id | type) == "string" and .id != "")
              | {key: "\($provider.key)/\($model.key)", id: .id, off: (.disabled == true)} ]
            | group_by(.key)
            | map({key: .[0].key,
                   value: {declared: (map(.id) | unique),
                           selectable: (map(select(.off | not) | .id) | unique)}})
            | from_entries
          else {} end;
        def clean_info:
          {model: (.model | model_value)}
          | with_entries(select(.value != null));
        def entries:
          if type == "array" then [.[] | {type, path, info:(.info // {})}]
          elif type == "object" then [{type:"document", path:($global + "/opencode.json"), info:.}]
          else error("unsupported debug config JSON shape") end;
        # The docs list keeps only the decoded model of each source and drops
        # everything else: the provider metadata the variant list above reads
        # stays behind here, because a config source can carry arbitrary
        # provider content the ranking step has no use for. Both passes carry
        # their own load.
        (entries) as $docs
        | {shape:(if type == "array" then "source-array" else "resolved-object" end),
           global:$global,
           docs:[$docs[] | {type, path, info:(.info | clean_info), variants:(.info | variant_map)}]}
    '
    # `debug config` output is redirected to a real file rather than piped
    # straight into jq: against the installed OpenCode CLI, piping its stdout
    # silently truncates at 64KiB, which breaks jq on any config past that
    # size. A regular file does not have that limit.
    raw_config="$result_dir/config.raw.json"
    # shellcheck disable=SC2016  # single quotes are deliberate: ${...} expands in the probe's bash -c, not here
    if fm_run_timed "$bound" /bin/bash -c '
      "$1" debug config > "$2" 2>/dev/null
      status=$?
      [ "$status" -eq 0 ] || exit "$status"
      jq -c --arg global "$3" "$4" < "$2"
    ' _ "$bin" "$raw_config" "$global_config" "$normalize_filter" > "$result_dir/config.json"; then
      printf '0\n' > "$result_dir/config.status"
    else
      status=$?
      [ "$status" -ne 0 ] || status=65
      printf '%s\n' "$status" > "$result_dir/config.status"
    fi
    rm -f "$raw_config" 2>/dev/null || true
  fi
  fi
else
  printf '{"shape":"skip"}\n' > "$result_dir/config.json"
  printf '0\n' > "$result_dir/config.status"
fi

if fm_run_timed "$bound" "$bin" models > "$result_dir/models.txt" 2>/dev/null < /dev/null; then
  printf '0\n' > "$result_dir/models.status"
else
  status=$?
  printf '%s\n' "$status" > "$result_dir/models.status"
fi

: > "$result_dir/done"
