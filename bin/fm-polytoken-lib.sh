#!/usr/bin/env bash
# fm-polytoken-lib.sh - the one owner of Firstmate's Polytoken worker mechanics.
#
# Sourced, never executed; defining these functions has no side effects.
# Callers must also source bin/fm-timeout-lib.sh (fm_run_timed) and have jq.
# Polytoken is verified for crewmate and scout work only; the evidence lives in
# docs/verification/polytoken.md and the operating facts in
# .agents/skills/harness-adapters/references/harness/polytoken.md.
#
# Worker overlay. Polytoken reads hooks only from hooks.json in the global
# config directory and in the project's .polytoken/ directory, and has no
# per-invocation hook or permission flag: `polytoken --config-dir <dir>`
# starts an isolated daemon that loads neither the global layer nor
# project hooks. So each worker receives two Firstmate-owned files in its own
# worktree, kept out of git's view by the caller's info/exclude entry:
#   .polytoken/hooks.json   pre_user_prompt opens a turn and stop closes it
#                           through bin/fm-busy-event.sh; stop also touches the
#                           turn-ended wake notification after a successful
#                           generation-bound apply. The captain's global hooks
#                           still load first and keep running.
#   .polytoken/config.yaml  default_permission_matcher: bypass, so an
#                           unattended worker never stops on an approval.
# The global config, auth, and hooks are never read for writing or edited.
# A project that already owns either file, or any other .polytoken/config.*
# (Polytoken refuses a directory holding two config files), is refused rather
# than overwritten; only files carrying this overlay's own marker are replaced.
# Relaunch retirement (bin/fm-spawn.sh) and cleanup (bin/fm-teardown.sh) both
# remove them through fm_polytoken_remove_overlay, only while they carry the marker.
#
# Model and effort. `polytoken new --model` accepts only a fully qualified
# <provider>/<model> or one of its listed `<model>(<variant>)` selectors, and
# an unknown model or variant fails inside the pane after launch. The model is
# therefore validated against `polytoken models --format json` before any pane
# exists. Effort has no flag of its own: a requested level that the target
# model lists among its reasoning levels becomes the `<model>(<level>)`
# selector, and any other level is recorded by the caller but omitted. A model
# that already names a variant keeps it.
#
# Detached daemon. `polytoken new` double-forks a daemon (parent pid 1, its
# own process group, cwd = the project) and the pane holds only the TUI. A
# TUI that exits without /quit leaves the daemon running, and it continues any
# turn in flight, so a pane that reads agent-free does not prove the worktree
# is agent-free. fm_polytoken_wait_no_live_session is the spawn-side guard.

FM_POLYTOKEN_OVERLAY_MARK='# Firstmate Polytoken worker overlay'
FM_POLYTOKEN_HOOK_OPEN=firstmate-busy-open
FM_POLYTOKEN_HOOK_CLOSE=firstmate-busy-close

# The two overlay paths, relative to the worktree. The one list both the writer
# below and fm_polytoken_remove_overlay agree with.
fm_polytoken_overlay_relpaths() {
  printf '%s\n' .polytoken/hooks.json .polytoken/config.yaml
}

# The absolute polytoken executable from PATH, or failure.
fm_polytoken_resolve_binary() {
  local bin
  bin=$(command -v polytoken 2>/dev/null) || return 1
  case "$bin" in /*) printf '%s' "$bin" ;; *) return 1 ;; esac
}

# fm_polytoken_catalog <bin>: the `polytoken models --format json` document on
# stdout, bounded by FM_POLYTOKEN_MODELS_TIMEOUT seconds (default 15) with stdin
# detached. Exit 124 when the bound was hit; any other failure is nonzero.
fm_polytoken_catalog() {  # <bin>
  local bin=$1 bound=${FM_POLYTOKEN_MODELS_TIMEOUT:-15} out rc=0
  case "$bound" in ''|*[!0-9]*|0*) bound=15 ;; esac
  out=$(fm_run_timed "$bound" "$bin" models --format json 2>/dev/null < /dev/null) || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s' "$out" | jq -e '(.models | type) == "array"' >/dev/null 2>&1 || return 1
  printf '%s' "$out"
}

# fm_polytoken_model_arg <bin> <model> <effort>: print the value for
# `polytoken new --model`, or nothing when the launch should keep the
# configured default. Refuses (exit 1, reason on stderr) for a model or variant
# a reachable listing does not offer and for native `ultra`. Notices on stderr
# report an omitted effort or an unreachable listing.
fm_polytoken_model_arg() {  # <bin> <model> <effort>
  local bin=$1 model=${2:-} effort=${3:-} catalog rc=0 base target selectable levels
  [ "$model" != default ] || model=
  [ "$effort" != default ] || effort=
  [ -n "$model$effort" ] || return 0
  if [ "$effort" = ultra ]; then
    echo "error: polytoken has no native ultra effort; choose low, medium, high, xhigh, or max" >&2
    return 1
  fi
  catalog=$(fm_polytoken_catalog "$bin") || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 124 ]; then
      echo "notice: 'polytoken models' did not answer within the bound; launching without model validation" >&2
    else
      echo "notice: 'polytoken models' listing is unreadable (exit $rc); launching without model validation" >&2
    fi
    [ -z "$effort" ] || echo "notice: effort '$effort' cannot be mapped without the model listing; it is recorded but not applied" >&2
    printf '%s' "$model"
    return 0
  fi
  if [ -n "$model" ]; then
    base=${model%%(*}
    if ! printf '%s' "$catalog" | jq -e --arg m "$base" 'any(.models[]; .name == $m)' >/dev/null; then
      echo "error: polytoken model '$base' is not listed by 'polytoken models'; choose a listed <provider>/<model> or omit --model" >&2
      return 1
    fi
    if [ "$base" != "$model" ]; then
      selectable=$(printf '%s' "$catalog" | jq -e --arg m "$model" 'any(.models[]; (.selectable // []) | index($m))' 2>/dev/null) || selectable=false
      if [ "$selectable" != true ]; then
        echo "error: polytoken model selector '$model' is not among the variants 'polytoken models' lists for '$base'" >&2
        return 1
      fi
      [ -z "$effort" ] || echo "notice: polytoken model '$model' already names its variant; effort '$effort' is recorded but not applied" >&2
      printf '%s' "$model"
      return 0
    fi
  fi
  if [ -z "$effort" ]; then
    printf '%s' "$model"
    return 0
  fi
  target=${model:-$(printf '%s' "$catalog" | jq -r '.default_model // empty')}
  levels=$(printf '%s' "$catalog" | jq -r --arg m "$target" \
    '.models[] | select(.name == $m) | .reasoning | select(.type == "effort") | (.levels // [])[]' 2>/dev/null) || levels=
  if [ -n "$target" ] && printf '%s\n' "$levels" | grep -qxF -- "$effort"; then
    printf '%s(%s)' "$target" "$effort"
    return 0
  fi
  echo "notice: polytoken model '${target:-<default>}' lists no '$effort' reasoning level; effort is recorded but not applied" >&2
  printf '%s' "$model"
}

# Single-quote a value for a hook command line.
_fm_polytoken_quote() {  # <value>
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# True when <path> is a Firstmate overlay file written by this library.
_fm_polytoken_overlay_owned() {  # <path>
  local path=$1 first
  case "$path" in
    */hooks.json)
      jq -e --arg a "$FM_POLYTOKEN_HOOK_OPEN" --arg b "$FM_POLYTOKEN_HOOK_CLOSE" \
        'type == "array" and length > 0 and all(.[]; type == "object" and (.name == $a or .name == $b))' \
        "$path" >/dev/null 2>&1
      ;;
    *)
      IFS= read -r first < "$path" 2>/dev/null && [ "$first" = "$FM_POLYTOKEN_OVERLAY_MARK" ]
      ;;
  esac
}

# fm_polytoken_write_overlay <worktree> <state-dir> <id> <busy-gen> <turn-ended> <fm-root>
# Write both overlay files (header). Refuses, writing nothing, when the project
# owns either path, tracks it, or holds another .polytoken/config.* file.
fm_polytoken_write_overlay() {  # <wt> <state> <id> <gen> <turnend> <fm-root>
  local wt=$1 state=$2 id=$3 gen=$4 turnend=$5 root=$6 dir rel path sibling
  local prefix suffix open close tmp
  dir="$wt/.polytoken"
  while IFS= read -r rel; do
    path="$wt/$rel"
    if git -C "$wt" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1; then
      echo "error: this project tracks $rel, which the Polytoken worker overlay would replace; Polytoken reads hooks and permissions only from that project layer, so refusing rather than editing a tracked file" >&2
      return 1
    fi
    if [ -e "$path" ] || [ -L "$path" ]; then
      if [ ! -f "$path" ] || [ -L "$path" ] || ! _fm_polytoken_overlay_owned "$path"; then
        echo "error: $path already exists and is not Firstmate's Polytoken worker overlay; refusing to replace the project's own Polytoken configuration" >&2
        return 1
      fi
    fi
  done <<EOF
$(fm_polytoken_overlay_relpaths)
EOF
  for sibling in config.json config.json5 config.toml config.yml; do
    if [ -e "$dir/$sibling" ] || [ -L "$dir/$sibling" ]; then
      echo "error: $dir/$sibling exists; Polytoken refuses a directory holding two config files, so the worker's config.yaml cannot be added beside it" >&2
      return 1
    fi
  done
  mkdir -p "$dir" || return 1
  prefix="$(_fm_polytoken_quote "$root/bin/fm-busy-event.sh") apply $(_fm_polytoken_quote "$state") $(_fm_polytoken_quote "$id")"
  suffix="--gen $(_fm_polytoken_quote "$gen") --source polytoken-hook"
  open="$prefix busy $suffix --event pre-user-prompt >/dev/null 2>&1 || true"
  close="$prefix idle $suffix --event stop >/dev/null 2>&1 && touch $(_fm_polytoken_quote "$turnend"); true"
  tmp=$(mktemp "$dir/.fm-hooks.XXXXXX") || return 1
  if ! jq -n --arg open_name "$FM_POLYTOKEN_HOOK_OPEN" --arg close_name "$FM_POLYTOKEN_HOOK_CLOSE" \
      --arg open "$open" --arg close "$close" \
      '[{name: $open_name, event: "pre_user_prompt", handler: {bash: $open}},
        {name: $close_name, event: "stop", handler: {bash: $close}}]' > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$dir/hooks.json" || { rm -f "$tmp"; return 1; }
  tmp=$(mktemp "$dir/.fm-config.XXXXXX") || return 1
  if ! printf '%s\n%s\n%s\n' "$FM_POLYTOKEN_OVERLAY_MARK" \
      '# Written for one Firstmate task and removed at cleanup; never commit it.' \
      'default_permission_matcher: bypass' > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$dir/config.yaml" || { rm -f "$tmp"; return 1; }
}

# fm_polytoken_remove_overlay <worktree>: remove each overlay file that still
# carries this library's own marker, then the .polytoken directory if that left
# it empty. A same-named file the project owns is left alone, because deleting
# a tracked file would dirty the worktree cleanup is about to check.
fm_polytoken_remove_overlay() {  # <wt>
  local wt=$1 rel path
  [ -n "$wt" ] && [ -d "$wt" ] || return 0
  while IFS= read -r rel; do
    path="$wt/$rel"
    if [ -f "$path" ] && [ ! -L "$path" ] && _fm_polytoken_overlay_owned "$path"; then
      rm -f -- "$path"
    fi
  done <<EOF
$(fm_polytoken_overlay_relpaths)
EOF
  rmdir "$wt/.polytoken" 2>/dev/null || true
}

# fm_polytoken_live_sessions <bin> <dir>: print "<session-id> <pid>" for each
# live Polytoken session whose project is <dir> (compared physically). Exit 2
# when the listing cannot be read, which proves nothing either way.
fm_polytoken_live_sessions() {  # <bin> <dir>
  local bin=$1 dir=$2 phys listing rc=0
  phys=$(cd "$dir" 2>/dev/null && pwd -P) || phys=$dir
  listing=$(fm_run_timed 15 "$bin" sessions --format json 2>/dev/null < /dev/null) || rc=$?
  [ "$rc" -eq 0 ] || return 2
  printf '%s' "$listing" | jq -e 'type == "array"' >/dev/null 2>&1 || return 2
  printf '%s' "$listing" | jq -r --arg d "$phys" --arg raw "$dir" \
    '.[] | select(.project_path == $d or .project_path == $raw) | "\(.session_id) \(.pid)"'
}

# fm_polytoken_wait_no_live_session <bin> <dir> [bound-seconds]: succeed once
# no live Polytoken session is anchored at <dir>. A just-quit daemon drains for
# about five seconds, so the check polls up to the bound (default
# FM_POLYTOKEN_SESSION_DRAIN_WAIT, else 20 seconds) before
# refusing with the session ids named. An unreadable listing refuses too: a
# live daemon there would be a second agent writing the same worktree.
fm_polytoken_wait_no_live_session() {  # <bin> <dir> [bound]
  local bin=$1 dir=$2 bound=${3:-${FM_POLYTOKEN_SESSION_DRAIN_WAIT:-20}} waited=0 live rc
  case "$bound" in ''|*[!0-9]*) bound=20 ;; esac
  while :; do
    rc=0
    live=$(fm_polytoken_live_sessions "$bin" "$dir") || rc=$?
    if [ "$rc" -eq 2 ]; then
      echo "error: 'polytoken sessions' could not be read, so a detached Polytoken daemon still working in $dir cannot be ruled out; refusing to start another agent there" >&2
      return 1
    fi
    [ -n "$live" ] || return 0
    [ "$waited" -lt "$bound" ] || break
    sleep 1
    waited=$((waited + 1))
  done
  echo "error: a live Polytoken session is still anchored at $dir ($(printf '%s' "$live" | tr '\n' ' ' | sed 's/ $//')); its detached daemon may still be working there. Attach with 'polytoken attach <session-id>' to inspect it, or stop it with 'polytoken reap <session-id>', before launching another agent in this worktree" >&2
  return 1
}
