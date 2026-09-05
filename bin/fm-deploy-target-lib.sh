#!/usr/bin/env bash
# Load and validate one project's deploy target: the private facts about the
# machine that serves it, plus the fixed data the deploy procedure needs.
#
# The procedure itself lives in bin/fm-deploy.sh and is the same for every
# project. This file only supplies data, and it deliberately accepts DATA ONLY:
# no key may carry a shell command, a flag list, or anything else this home
# would execute. A shared template must not grow a per-user deploy language, and
# a config file that could name a command would be a way to run anything as the
# deploy user.
#
# The file lives at config/deploy-target/<project>: LOCAL and gitignored,
# because deploy/README.md is explicit that the host address, ssh user, and host
# paths belong in the operator's private record and not in a repository.
# docs/configuration.md owns the operator-facing description of every key.
#
# Sourced only; no side effects on source.

# Required keys, then optional ones. An unknown key is refused rather than
# ignored, so a typo surfaces instead of silently disabling a safety step.
FM_DEPLOY_TARGET_REQUIRED='host user checkout unit rollback_root health_url public_url public_expect'
FM_DEPLOY_TARGET_OPTIONAL='python bundle_path bundle_artifact bundle_workflow bundle_verify run_lock ssh_options'

# Declared here rather than only built by `printf -v` below, so every consumer
# (and shellcheck) can see the complete key set this library publishes.
# shellcheck disable=SC2034 # Public results consumed by sourcing callers.
{
  FM_DEPLOY_TGT_host=''
  FM_DEPLOY_TGT_user=''
  FM_DEPLOY_TGT_checkout=''
  FM_DEPLOY_TGT_unit=''
  FM_DEPLOY_TGT_rollback_root=''
  FM_DEPLOY_TGT_health_url=''
  FM_DEPLOY_TGT_public_url=''
  FM_DEPLOY_TGT_public_expect=''
  FM_DEPLOY_TGT_python=''
  FM_DEPLOY_TGT_bundle_path=''
  FM_DEPLOY_TGT_bundle_artifact=''
  FM_DEPLOY_TGT_bundle_workflow=''
  FM_DEPLOY_TGT_bundle_verify=''
  FM_DEPLOY_TGT_run_lock=''
  FM_DEPLOY_TGT_ssh_options=''
}

# fm_deploy_target_load <home> <project>
# Sets FM_DEPLOY_TGT_<key> for every key, empty for an absent optional one.
fm_deploy_target_load() {
  local home=$1 project=$2 file line key value known k missing
  file=$(fm_deploy_target_file "$home" "$project")
  if [ ! -f "$file" ] || [ -L "$file" ] || [ ! -r "$file" ]; then
    printf 'error: %s has a deploy policy but no readable deploy target at %s\n' "$project" "$file" >&2
    return 2
  fi

  for key in $FM_DEPLOY_TARGET_REQUIRED $FM_DEPLOY_TARGET_OPTIONAL; do
    printf -v "FM_DEPLOY_TGT_${key}" '%s' ''
  done

  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [ -n "$line" ] || continue
    case "$line" in
      *=*) ;;
      *)
        printf 'error: %s: not a key=value line: %s\n' "$file" "$line" >&2
        return 2
        ;;
    esac
    key=${line%%=*}
    value=${line#*=}
    key=${key%"${key##*[![:space:]]}"}
    value=${value#"${value%%[![:space:]]*}"}
    known=0
    for k in $FM_DEPLOY_TARGET_REQUIRED $FM_DEPLOY_TARGET_OPTIONAL; do
      [ "$k" = "$key" ] && known=1 && break
    done
    if [ "$known" -eq 0 ]; then
      printf 'error: %s: unknown key %s\n' "$file" "$key" >&2
      return 2
    fi
    # Data only. Anything that could end a word and start a command is refused
    # here rather than quoted later and hoped about.
    case "$value" in
      *[\;\&\|\`\$\<\>\(\)]* | *$'\n'*)
        printf 'error: %s: key %s carries shell metacharacters; deploy target values are data only\n' "$file" "$key" >&2
        return 2
        ;;
    esac
    printf -v "FM_DEPLOY_TGT_${key}" '%s' "$value"
  done <"$file"

  missing=''
  for key in $FM_DEPLOY_TARGET_REQUIRED; do
    [ -n "${!key+x}" ] || :
    eval "value=\${FM_DEPLOY_TGT_${key}}"
    [ -n "$value" ] || missing="$missing $key"
  done
  if [ -n "$missing" ]; then
    printf 'error: %s: required key(s) missing:%s\n' "$file" "$missing" >&2
    return 2
  fi

  # A bundle is either fully described or absent; a half-described one would
  # deploy a version whose front end nobody obtained.
  if [ -n "$FM_DEPLOY_TGT_bundle_path" ]; then
    if [ -z "$FM_DEPLOY_TGT_bundle_artifact" ] || [ -z "$FM_DEPLOY_TGT_bundle_workflow" ]; then
      printf 'error: %s: bundle_path needs both bundle_artifact and bundle_workflow\n' "$file" >&2
      return 2
    fi
  fi
  [ -n "$FM_DEPLOY_TGT_python" ] || FM_DEPLOY_TGT_python="$FM_DEPLOY_TGT_checkout/.venv/bin/python"
  return 0
}

# fm_deploy_ssh <command...>
# One ssh entry point, batch-mode and bounded, so no deploy step can sit waiting
# on an interactive prompt.
fm_deploy_ssh() {
  # shellcheck disable=SC2086 # ssh_options is a validated, metacharacter-free word list.
  ssh -o BatchMode=yes -o ConnectTimeout="${FM_DEPLOY_SSH_CONNECT_TIMEOUT:-10}" \
    $FM_DEPLOY_TGT_ssh_options \
    "$FM_DEPLOY_TGT_user@$FM_DEPLOY_TGT_host" "$@"
}

# fm_deploy_host_sha
# The commit the host actually runs. `git rev-parse` is a read; the checkout is
# root-owned and carries no safe.directory exception on purpose, so this reads
# it as root rather than working around the ownership check.
fm_deploy_host_sha() {
  fm_deploy_ssh "sudo git -C '$FM_DEPLOY_TGT_checkout' rev-parse HEAD" 2>/dev/null
}
