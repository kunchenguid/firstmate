# shellcheck shell=bash
# A launch's environment axis: validating a --env path, and detecting when a
# claude launch needs one because its --model carries a routing qualifier.
# Shared by bin/fm-spawn.sh (the launch owner, which composes and sources the
# file) and bin/fm-control.sh (which must refuse a bad launch BEFORE stopping
# the agent a relaunch would replace, not after - see do_relaunch/
# resolve_relaunch_profile). Depends on fm_backlog_bytes_of_string and
# fm_backlog_control_bytes_valid from bin/fm-backlog-transition-lib.sh, which
# every caller sources first.

# resolve_env_file: validate ONE launch environment file path without ever
# opening it. The path is all Firstmate is allowed to know: the file holds live
# credentials, so its contents must never reach state/<id>.meta, the launch
# text, pane scrollback, or a log, and the values are expanded by the
# destination pane instead (see bin/fm-spawn.sh's header --env contract).
# Absolute only, because the pane resolves it rather than this process, and it
# must be a readable regular file (symlinks to one are fine, a dangling
# symlink or a directory is not). Every refusal names the path and nothing
# else.
resolve_env_file() {  # <path>
  local path=$1 raw_bytes
  raw_bytes=$(fm_backlog_bytes_of_string "$path") || return 1
  if ! fm_backlog_control_bytes_valid 0 "$raw_bytes"; then
    echo "error: --env path contains an invalid control byte" >&2
    return 1
  fi
  case "$path" in
    /*) ;;
    *) echo "error: --env must be an absolute path; the destination pane resolves it, not this process (got '$path')" >&2; return 1 ;;
  esac
  if [ ! -f "$path" ] || [ ! -r "$path" ]; then
    echo "error: --env file is missing, unreadable, or not a regular file: $path" >&2
    return 1
  fi
  printf '%s\n' "$path"
}

# claude pre-launch model/environment guard, the counterpart to
# omp_model_validate in bin/fm-spawn.sh for the one harness with no local model
# catalog to validate against.
#
# claude's own --help (Claude Code 2.1.263) documents its native id space as a
# short alias for the latest model - fable, opus, sonnet - or a model's full
# name, claude-fable-5. An id carrying a ROUTING QUALIFIER instead names a
# target claude's default first-party endpoint cannot serve: a provider or path
# segment (openai/gpt-5.6-luna), a resource qualifier
# (arn:aws:bedrock:...:inference-profile/...), or a vendor-dotted prefix
# (us.anthropic.claude-sonnet-5, which needs CLAUDE_CODE_USE_BEDROCK). The
# qualifier test rather than a bare slash test is what puts the dotted Bedrock
# id on the correct side by construction instead of by accident.
#
# Asking for such an id anyway does not fail. Verified empirically 2026-09-07 on
# Claude Code 2.1.263: `claude -p 'Say OK' --model openai/gpt-5.6-luna
# --output-format json` answered from modelUsage claude-sonnet-5 with
# canonicalModel claude-sonnet-5, provider firstParty, is_error false, exit
# status 0, and nothing on stderr. That silent substitution is the reason a
# claude launch naming a qualified id REQUIRES an explicit launch environment
# (--env, or a crew-dispatch profile env field) and refuses without one.
#
# What this does NOT claim: it cannot tell a real first-party id from a
# plausible one, because claude publishes no local catalog to check against, so
# a misspelled claude-* name still reaches the same silent fallback. The guard
# covers exactly the class an environment grant is the fix for.
claude_model_needs_launch_environment() {  # <model>
  local model=$1
  [ -n "$model" ] && [ "$model" != default ] || return 1
  case "$model" in
    */*|*:*) return 0 ;;
    claude*) return 1 ;;
    *.*) return 0 ;;
    *) return 1 ;;
  esac
}
