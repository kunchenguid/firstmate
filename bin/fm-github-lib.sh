#!/usr/bin/env bash
# Authoritative process policy for optional per-project GitHub account routing.
# docs/configuration.md owns the complete config/github-accounts.json schema.
# This library resolves one stable profile, installs a process-local exact child
# context, validates repository-controlled Git routing by key name, and invokes
# exact configured binaries with argv arrays. It never reads or prints tokens,
# credential-helper responses, complete environments, or child authentication
# errors.

FM_GITHUB_MODE=${FM_GITHUB_MODE:-legacy}
FM_GITHUB_PROFILE_ID=${FM_GITHUB_PROFILE_ID:-}
FM_GITHUB_GH_BINARY=${FM_GITHUB_GH_BINARY:-}
FM_GITHUB_GIT_BINARY=${FM_GITHUB_GIT_BINARY:-}
FM_GITHUB_GH_AXI_BINARY=${FM_GITHUB_GH_AXI_BINARY:-}
FM_GITHUB_GH_CONFIG_DIR=${FM_GITHUB_GH_CONFIG_DIR:-}
FM_GITHUB_HOST=${FM_GITHUB_HOST:-}
FM_GITHUB_EXPECTED_LOGIN=${FM_GITHUB_EXPECTED_LOGIN:-}
FM_GITHUB_FORK_OWNER=${FM_GITHUB_FORK_OWNER:-}
FM_GITHUB_COMMIT_NAME=${FM_GITHUB_COMMIT_NAME:-}
FM_GITHUB_COMMIT_EMAIL=${FM_GITHUB_COMMIT_EMAIL:-}
FM_GITHUB_REPOSITORY=${FM_GITHUB_REPOSITORY:-}
FM_GITHUB_PROJECT=${FM_GITHUB_PROJECT:-}
FM_GITHUB_PROJECT_PATH=${FM_GITHUB_PROJECT_PATH:-}

fm_github_lib_dir() {
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

fm_github_root() {
  if [ -n "${FM_ROOT_OVERRIDE:-}" ]; then
    printf '%s\n' "$FM_ROOT_OVERRIDE"
  else
    cd "$(fm_github_lib_dir)/.." && pwd
  fi
}

fm_github_home() {
  printf '%s\n' "${FM_HOME:-${FM_ROOT_OVERRIDE:-$(fm_github_root)}}"
}

fm_github_config_path() {
  printf '%s\n' "${FM_GITHUB_CONFIG:-${FM_CONFIG_OVERRIDE:-$(fm_github_home)/config}/github-accounts.json}"
}

fm_github_enabled() {
  [ -e "$(fm_github_config_path)" ] || [ -L "$(fm_github_config_path)" ]
}

fm_github_reset_context() {
  FM_GITHUB_MODE=legacy
  FM_GITHUB_PROFILE_ID=
  FM_GITHUB_GH_BINARY=
  FM_GITHUB_GIT_BINARY=
  FM_GITHUB_GH_AXI_BINARY=
  FM_GITHUB_GH_CONFIG_DIR=
  FM_GITHUB_HOST=
  FM_GITHUB_EXPECTED_LOGIN=
  FM_GITHUB_FORK_OWNER=
  FM_GITHUB_COMMIT_NAME=
  FM_GITHUB_COMMIT_EMAIL=
  FM_GITHUB_REPOSITORY=
  FM_GITHUB_PROJECT=
  FM_GITHUB_PROJECT_PATH=
}

fm_github_parse_fields() {
  local output=$1 line key value
  while IFS= read -r line || [ -n "$line" ]; do
    key=${line%%$'\t'*}
    [ "$line" != "$key" ] || return 1
    value=${line#*$'\t'}
    case "$key" in
      mode) FM_GITHUB_MODE=$value ;;
      profile_id) FM_GITHUB_PROFILE_ID=$value ;;
      gh_binary) FM_GITHUB_GH_BINARY=$value ;;
      git_binary) FM_GITHUB_GIT_BINARY=$value ;;
      gh_axi_binary) FM_GITHUB_GH_AXI_BINARY=$value ;;
      gh_config_dir) FM_GITHUB_GH_CONFIG_DIR=$value ;;
      host) FM_GITHUB_HOST=$value ;;
      expected_login) FM_GITHUB_EXPECTED_LOGIN=$value ;;
      fork_owner) FM_GITHUB_FORK_OWNER=$value ;;
      commit_name) FM_GITHUB_COMMIT_NAME=$value ;;
      commit_email) FM_GITHUB_COMMIT_EMAIL=$value ;;
      repository) FM_GITHUB_REPOSITORY=$value ;;
      project) FM_GITHUB_PROJECT=$value ;;
      *) return 1 ;;
    esac
  done <<< "$output"
}

fm_github_node() {
  local node_binary
  node_binary=$(command -v node) || return 1
  env -u NODE_OPTIONS -u NODE_PATH "$node_binary" "$@"
}

fm_github_validate_config() {
  local output
  fm_github_reset_context
  output=$(fm_github_node "$(fm_github_lib_dir)/fm-github-config.mjs" validate) || return 1
  fm_github_parse_fields "$output" || {
    echo "error: invalid GitHub account routing configuration" >&2
    return 1
  }
  [ "$FM_GITHUB_MODE" = legacy ] || [ "$FM_GITHUB_MODE" = strict ]
}

fm_github_configured_git() {
  local output line key value
  if ! fm_github_enabled; then
    command -v git
    return
  fi
  output=$(fm_github_node "$(fm_github_lib_dir)/fm-github-config.mjs" validate) || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    key=${line%%$'\t'*}
    value=${line#*$'\t'}
    [ "$key" != git_binary ] || { printf '%s\n' "$value"; return 0; }
  done <<< "$output"
  return 1
}

fm_github_repository_from_path() {
  local repo_path=$1 git_binary raw
  git_binary=$(fm_github_configured_git) || return 1
  raw=$(
    fm_github_unset_ambient
    # This export intentionally exists only inside the origin-read substitution.
    # shellcheck disable=SC2030
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
    "$git_binary" -C "$repo_path" config --local --get remote.origin.url 2>/dev/null
  ) || {
      echo "error: project origin is unavailable for GitHub account routing" >&2
      return 1
    }
  printf '%s\n' "$raw"
}

fm_github_resolve() {
  local project=${1:-} repository_input=${2:-} required_profile=${3:-} repository output
  fm_github_reset_context
  if ! fm_github_enabled; then
    if [ -n "$required_profile" ]; then
      echo "error: the recorded GitHub account profile cannot be used because strict routing is no longer configured" >&2
      return 1
    fi
    return 0
  fi
  [ -n "$repository_input" ] || {
    echo "error: strict GitHub account routing requires a repository" >&2
    return 1
  }
  if [ -d "$repository_input" ]; then
    repository=$(fm_github_repository_from_path "$repository_input") || return 1
  else
    repository=$repository_input
  fi
  local args=(resolve --repository "$repository")
  [ -z "$project" ] || args+=(--project "$project")
  [ -z "$required_profile" ] || args+=(--profile "$required_profile")
  output=$(fm_github_node "$(fm_github_lib_dir)/fm-github-config.mjs" "${args[@]}") || return 1
  fm_github_parse_fields "$output" || {
    echo "error: invalid GitHub account routing result" >&2
    return 1
  }
  [ "$FM_GITHUB_MODE" = strict ] && [ -n "$FM_GITHUB_PROFILE_ID" ] && [ -n "$FM_GITHUB_REPOSITORY" ] || return 1
}

fm_github_canonical_repository() {
  local raw=$1 output line key value
  output=$(fm_github_node "$(fm_github_lib_dir)/fm-github-config.mjs" canonicalize-repository --repository "$raw") || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    key=${line%%$'\t'*}
    value=${line#*$'\t'}
    if [ "$key" = repository ] && [ "$line" != "$key" ]; then
      printf '%s\n' "$value"
      return 0
    fi
  done <<< "$output"
  return 1
}

fm_github_repository_allowed() {
  local raw=$1 canonical target owner repo parent_owner parent_repo
  canonical=$(fm_github_canonical_repository "$raw") || return 1
  target=${canonical#github.com/}
  owner=${target%%/*}
  repo=${target#*/}
  target=${FM_GITHUB_REPOSITORY#github.com/}
  parent_owner=${target%%/*}
  parent_repo=${target#*/}
  [ "$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$parent_repo" | tr '[:upper:]' '[:lower:]')" ] || return 1
  if [ "$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$parent_owner" | tr '[:upper:]' '[:lower:]')" ]; then
    [ -n "$FM_GITHUB_FORK_OWNER" ] || return 1
    [ "$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$FM_GITHUB_FORK_OWNER" | tr '[:upper:]' '[:lower:]')" ] || return 1
  fi
  printf '%s\n' "$canonical"
}

fm_github_shell_quote() {
  local value=$1
  value=${value//\'/\'\\\'\'}
  printf "'%s'" "$value"
}

fm_github_unset_ambient() {
  local name
  unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN GH_CONFIG_DIR GH_HOST GH_REPO GH_PROMPT_DISABLED GH_NO_UPDATE_NOTIFIER
  unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM
  unset GIT_ASKPASS SSH_ASKPASS SSH_ASKPASS_REQUIRE GIT_SSH GIT_SSH_COMMAND GIT_SSH_VARIANT SSH_AUTH_SOCK
  unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL EMAIL
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE
  unset GIT_EXEC_PATH GIT_TEMPLATE_DIR GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_PROXY_COMMAND GIT_CURL_VERBOSE
  unset GIT_SSL_NO_VERIFY GIT_SSL_CAINFO GIT_SSL_CAPATH GIT_SSL_CERT GIT_SSL_KEY GIT_SSL_CERT_PASSWORD_PROTECTED GIT_SSL_VERSION GIT_SSL_CIPHER_LIST
  unset GIT_HTTP_PROXY GIT_HTTPS_PROXY HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy
  unset CURL_CA_BUNDLE CURL_SSL_BACKEND SSL_CERT_FILE SSL_CERT_DIR OPENSSL_CONF OPENSSL_MODULES
  unset GIT_TERMINAL_PROMPT GCM_INTERACTIVE GIT_EDITOR GIT_SEQUENCE_EDITOR GIT_MERGE_AUTOEDIT EDITOR VISUAL GIT_PAGER PAGER
  unset BASH_ENV ENV CDPATH NODE_OPTIONS NODE_PATH RUBYOPT PERL5OPT PYTHONPATH PYTHONHOME
  while IFS= read -r name; do
    case "$name" in
      GIT_CONFIG_KEY_*|GIT_CONFIG_VALUE_*|GIT_TRACE*) unset "$name" ;;
    esac
  done < <(compgen -v)
}

fm_github_add_git_config() {
  local key=$1 value=$2 index=${GIT_CONFIG_COUNT:-0}
  export "GIT_CONFIG_KEY_$index=$key"
  export "GIT_CONFIG_VALUE_$index=$value"
  export GIT_CONFIG_COUNT=$((index + 1))
}

fm_github_activate() {
  local project=${1:-} repository=${2:-} required_profile=${3:-} old_path helper shim_dir selected_path inherited_project_path
  inherited_project_path=${FM_GITHUB_PROJECT_PATH:-}
  fm_github_resolve "$project" "$repository" "$required_profile" || return 1
  [ "$FM_GITHUB_MODE" = strict ] || return 0
  old_path=${PATH:-/usr/bin:/bin}
  fm_github_unset_ambient
  shim_dir="$(fm_github_lib_dir)/github-path"
  selected_path="$shim_dir:$(dirname "$FM_GITHUB_GH_AXI_BINARY"):$old_path"
  helper="!$(fm_github_shell_quote "$FM_GITHUB_GH_BINARY") auth git-credential"
  export PATH=$selected_path
  export GH_CONFIG_DIR=$FM_GITHUB_GH_CONFIG_DIR GH_HOST=$FM_GITHUB_HOST GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1
  # The earlier origin read is a separate substitution; these exports own the
  # actual selected child context in this shell.
  # shellcheck disable=SC2031
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=Never
  export GIT_EDITOR=true GIT_SEQUENCE_EDITOR=true GIT_MERGE_AUTOEDIT=no EDITOR=true VISUAL=true GIT_PAGER=cat PAGER=cat
  export GIT_CONFIG_COUNT=0
  fm_github_add_git_config credential.helper ""
  fm_github_add_git_config "credential.https://github.com.helper" ""
  fm_github_add_git_config "credential.https://github.com.helper" "$helper"
  fm_github_add_git_config credential.useHttpPath false
  fm_github_add_git_config http.extraHeader ""
  fm_github_add_git_config "http.https://github.com/.extraHeader" ""
  fm_github_add_git_config core.askPass ""
  fm_github_add_git_config core.sshCommand ""
  if [ -n "$FM_GITHUB_COMMIT_NAME" ]; then
    fm_github_add_git_config user.name "$FM_GITHUB_COMMIT_NAME"
    fm_github_add_git_config user.email "$FM_GITHUB_COMMIT_EMAIL"
  fi
  fm_github_add_git_config user.useConfigOnly true
  if [ -d "$repository" ]; then
    FM_GITHUB_PROJECT_PATH=$(cd "$repository" && pwd -P)
  else
    FM_GITHUB_PROJECT_PATH=$inherited_project_path
  fi
  export FM_GITHUB_ACTIVE=1 FM_GITHUB_PROFILE_ID FM_GITHUB_GH_BINARY FM_GITHUB_GIT_BINARY FM_GITHUB_GH_AXI_BINARY
  export FM_GITHUB_GH_CONFIG_DIR FM_GITHUB_HOST FM_GITHUB_EXPECTED_LOGIN FM_GITHUB_FORK_OWNER FM_GITHUB_REPOSITORY FM_GITHUB_PROJECT FM_GITHUB_PROJECT_PATH
}

fm_github_unsafe_git_key() {
  local key
  key=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$key" in
    credential.*|http.*|include.*|includeif.*|url.*|protocol.*|ssh.*|core.sshcommand|core.askpass|core.gitproxy|core.editor|sequence.editor|gpg.*|remote.*.pushurl|remote.*.proxy|remote.*.proxyauthmethod|remote.*.uploadpack|remote.*.receivepack)
      return 0
      ;;
  esac
  return 1
}

fm_github_validate_local_config() {
  local repo_path=${1:-} scope output key
  [ "$FM_GITHUB_MODE" = strict ] || return 0
  [ -n "$repo_path" ] && [ -d "$repo_path" ] || return 0
  for scope in --local --worktree; do
    if ! output=$("$FM_GITHUB_GIT_BINARY" -C "$repo_path" config "$scope" --name-only --list 2>/dev/null); then
      if [ "$scope" = --worktree ] \
        && [ "$("$FM_GITHUB_GIT_BINARY" -C "$repo_path" config --local --get extensions.worktreeConfig 2>/dev/null || true)" != true ]; then
        continue
      fi
      echo "error: cannot inspect repository-controlled Git configuration for profile $FM_GITHUB_PROFILE_ID" >&2
      return 1
    fi
    while IFS= read -r key || [ -n "$key" ]; do
      [ -n "$key" ] || continue
      if fm_github_unsafe_git_key "$key"; then
        echo "error: repository-controlled credential, include, URL rewrite, proxy, TLS, certificate, cookie, authorization-header, editor, prompt, or transport override is forbidden" >&2
        return 1
      fi
    done <<< "$output"
  done
}

fm_github_classify_failure() {
  local child_output=$1 operation=$2
  if grep -Eqi '(^|[^0-9])401([^0-9]|$)|bad credentials|authentication.*(failed|required)' <<< "$child_output"; then
    echo "error: GitHub profile $FM_GITHUB_PROFILE_ID is expired or unauthenticated during $operation" >&2
  elif grep -Eqi 'saml|single sign|sso|organization.*authoriz' <<< "$child_output"; then
    echo "error: GitHub profile $FM_GITHUB_PROFILE_ID requires organization SSO authorization during $operation" >&2
  elif grep -Eqi '(^|[^0-9])403([^0-9]|$)|forbidden' <<< "$child_output"; then
    echo "error: GitHub profile $FM_GITHUB_PROFILE_ID lacks repository permission or organization SSO authorization during $operation" >&2
  elif grep -Eqi '(^|[^0-9])404([^0-9]|$)|not found' <<< "$child_output"; then
    echo "error: repository is inaccessible through GitHub profile $FM_GITHUB_PROFILE_ID during $operation" >&2
  else
    echo "error: GitHub profile $FM_GITHUB_PROFILE_ID could not complete $operation" >&2
  fi
}

fm_github_preflight_login() {
  local auth_output login_output login
  [ "$FM_GITHUB_MODE" = strict ] || return 0
  if ! auth_output=$("$FM_GITHUB_GH_BINARY" auth status --hostname "$FM_GITHUB_HOST" --active 2>&1); then
    fm_github_classify_failure "$auth_output" "authentication validation"
    return 1
  fi
  if ! grep -Eqi 'keyring|keychain|secure storage' <<< "$auth_output"; then
    echo "error: GitHub profile $FM_GITHUB_PROFILE_ID is not confirmed in secure credential storage" >&2
    return 1
  fi
  if ! login_output=$("$FM_GITHUB_GH_BINARY" api --hostname "$FM_GITHUB_HOST" user --jq .login 2>&1); then
    fm_github_classify_failure "$login_output" "login validation"
    return 1
  fi
  login=${login_output%%$'\n'*}
  if [ "$(printf '%s' "$login" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$FM_GITHUB_EXPECTED_LOGIN" | tr '[:upper:]' '[:lower:]')" ]; then
    echo "error: GitHub profile $FM_GITHUB_PROFILE_ID is authenticated as a different login" >&2
    return 1
  fi
}

fm_github_preflight() {
  local permission=${1:-read} target_repository=${2:-$FM_GITHUB_REPOSITORY} canonical repo_slug permission_output rc
  [ "$FM_GITHUB_MODE" = strict ] || return 0
  canonical=$(fm_github_repository_allowed "$target_repository") || {
    echo "error: GitHub profile $FM_GITHUB_PROFILE_ID cannot access a repository outside the configured parent or fork route" >&2
    return 1
  }
  repo_slug=${canonical#github.com/}
  fm_github_preflight_login || return 1
  if ! permission_output=$("$FM_GITHUB_GH_BINARY" repo view "$repo_slug" --json viewerPermission --jq .viewerPermission 2>&1); then
    fm_github_classify_failure "$permission_output" "repository access validation"
    return 1
  fi
  rc=${permission_output%%$'\n'*}
  case "$rc" in
    READ|TRIAGE|WRITE|MAINTAIN|ADMIN) ;;
    *)
      echo "error: GitHub profile $FM_GITHUB_PROFILE_ID returned an invalid repository permission" >&2
      return 1
      ;;
  esac
  if [ "$permission" = write ]; then
    case "$rc" in
      WRITE|MAINTAIN|ADMIN) ;;
      *)
        echo "error: GitHub profile $FM_GITHUB_PROFILE_ID does not have write permission for this repository" >&2
        return 1
        ;;
    esac
  fi
}

fm_github_git_remote_is_read_only() {
  local arg command_seen=0
  for arg in "$@"; do
    if [ "$command_seen" -eq 0 ]; then
      [ "$arg" != remote ] || command_seen=1
      continue
    fi
    case "$arg" in
      -*) continue ;;
      get-url) return 0 ;;
      *) return 1 ;;
    esac
  done
  return 0
}

fm_github_git_operation() {
  local arg command_name='' next_is_config=0 next_is_value=0
  for arg in "$@"; do
    if [ "$next_is_value" -eq 1 ]; then next_is_value=0; continue; fi
    if [ "$next_is_config" -eq 1 ]; then
      next_is_config=0
      case "${arg%%=*}" in
        credential.*|http.*|include.*|includeif.*|url.*|protocol.*|ssh.*|core.sshCommand|core.askPass|core.gitProxy|core.editor|sequence.editor|gpg.*)
          printf forbidden
          return
          ;;
      esac
      continue
    fi
    case "$arg" in
      -c) next_is_config=1; continue ;;
      -c*)
        if fm_github_unsafe_git_key "${arg#-c}"; then printf forbidden; return; fi
        continue
        ;;
      -C) next_is_value=1; continue ;;
      --git-dir|--work-tree) next_is_value=1; continue ;;
      --git-dir=*|--work-tree=*|--namespace=*|--exec-path=*|--config-env=*) printf forbidden; return ;;
      -*) continue ;;
      *) command_name=$arg; break ;;
    esac
  done
  case "$command_name" in
    credential|credential-*|submodule) printf forbidden ;;
    remote)
      if fm_github_git_remote_is_read_only "$@"; then printf local; else printf forbidden; fi
      ;;
    config)
      for arg in "$@"; do
        case "$arg" in --global|--system|--file|--file=*|--blob|--blob=*) printf forbidden; return ;; esac
        if fm_github_unsafe_git_key "${arg%%=*}"; then printf forbidden; return; fi
      done
      printf local
      ;;
    push) printf push ;;
    clone|fetch|pull|ls-remote) printf network ;;
    *) printf local ;;
  esac
}

fm_github_git_network_repository() {
  local cwd=$PWD command='' command_seen=0 expect_cwd=0 expect_global_value=0 expect_option_value=0 arg target='' raw
  for arg in "$@"; do
    if [ "$expect_cwd" -eq 1 ]; then cwd=$arg; expect_cwd=0; continue; fi
    if [ "$expect_global_value" -eq 1 ]; then expect_global_value=0; continue; fi
    if [ "$command_seen" -eq 0 ]; then
      case "$arg" in
        -C) expect_cwd=1 ;;
        -c|--git-dir|--work-tree) expect_global_value=1 ;;
        -*) ;;
        *) command=$arg; command_seen=1 ;;
      esac
      continue
    fi
    if [ "$expect_option_value" -eq 1 ]; then expect_option_value=0; continue; fi
    case "$command" in
      push)
        case "$arg" in -o|--push-option|--repo) expect_option_value=1 ;; -*) ;; *) target=$arg; break ;; esac
        ;;
      clone)
        case "$arg" in
          -b|--branch|--depth|--shallow-since|--shallow-exclude|--reference|--reference-if-able|--separate-git-dir|--origin|-o|--upload-pack|-u|--template|--config|-c|--filter|--server-option|--revision|--bundle-uri) expect_option_value=1 ;;
          -*) ;;
          *) target=$arg; break ;;
        esac
        ;;
      fetch|pull|ls-remote)
        case "$arg" in
          --depth|--deepen|--shallow-since|--shallow-exclude|--upload-pack|--server-option|--negotiation-tip|--jobs|-j|--filter|--sort) expect_option_value=1 ;;
          --all|--multiple) return 1 ;;
          -*) ;;
          *) target=$arg; break ;;
        esac
        ;;
    esac
  done
  [ -n "$command" ] || return 1
  [ -n "$target" ] || target=origin
  case "$target" in
    https://*) raw=$target ;;
    *://*|*@*|*:*|/*) return 1 ;;
    *)
      case "$target" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
      raw=$("$FM_GITHUB_GIT_BINARY" -C "$cwd" config --local --get "remote.$target.url" 2>/dev/null) || return 1
      ;;
  esac
  fm_github_repository_allowed "$raw"
}

fm_github_validate_gh_resource() {
  local first=${1:-} second=${2:-} arg expect_repo=0 candidate canonical
  [ "$first" != api ] || return 1
  for arg in "$@"; do
    if [ "$expect_repo" -eq 1 ]; then
      candidate=$arg
      expect_repo=0
    else
      case "$arg" in
        --repo|-R) expect_repo=1; continue ;;
        --repo=*) candidate=${arg#--repo=} ;;
        -R?*) candidate=${arg#-R} ;;
        *) continue ;;
      esac
    fi
    canonical=$(fm_github_repository_allowed "$candidate") || return 1
    [ -n "$canonical" ] || return 1
  done
  [ "$expect_repo" -eq 0 ] || return 1
  if [ "$first" = repo ] && [ -n "${3:-}" ] && [ "${3#-}" = "${3}" ]; then
    fm_github_repository_allowed "$3" >/dev/null || return 1
  fi
  if [ "$first" = pr ]; then
    case "${3:-}" in
      https://github.com/*) fm_github_repository_allowed "$3" >/dev/null || return 1 ;;
    esac
  fi
}

fm_github_gh_operation() {
  local first=${1:-} second=${2:-} arg
  for arg in "$@"; do
    case "$arg" in --show-token|--show-token=*) printf forbidden; return ;; esac
  done
  if [ "$first" = auth ]; then
    case "$second" in
      status) printf helper ;;
      git-credential|login|switch|logout|refresh|token|setup-git) printf forbidden ;;
      *) printf forbidden ;;
    esac
    return
  fi
  case "$first" in
    --version|-v|version|help|--help|-h|completion) printf local ;;
    api) printf forbidden ;;
    pr)
      case "$second" in create|edit|merge|close|reopen|ready|review|comment|update-branch|revert) printf write ;; *) printf read ;; esac
      ;;
    repo)
      case "$second" in create) printf create ;; view|list|clone) printf read ;; *) printf forbidden ;; esac
      ;;
    issue)
      case "$second" in create|edit|close|reopen|comment|delete) printf write ;; *) printf read ;; esac
      ;;
    secret|variable) printf write ;;
    workflow)
      case "$second" in run|enable|disable) printf write ;; *) printf read ;; esac
      ;;
    run)
      case "$second" in cancel|delete|rerun|watch) printf write ;; *) printf read ;; esac
      ;;
    release)
      case "$second" in create|edit|delete|upload|delete-asset) printf write ;; *) printf read ;; esac
      ;;
    *) printf read ;;
  esac
}

fm_github_context_command() {
  local project=$1 repository=$2 required_profile=$3 tool=$4
  shift 4
  fm_github_activate "$project" "$repository" "$required_profile" || return 1
  if [ "$FM_GITHUB_MODE" = legacy ]; then
    command "$tool" "$@"
    return
  fi
  local repo_path='' operation target_repository github_binary
  if [ -d "$repository" ]; then
    repo_path=$repository
  elif [ -n "${FM_GITHUB_PROJECT_PATH:-}" ] && [ -d "$FM_GITHUB_PROJECT_PATH" ]; then
    repo_path=$FM_GITHUB_PROJECT_PATH
  fi
  fm_github_validate_local_config "${repo_path:-}" || return 1
  case "${tool##*/}" in
    git)
      operation=$(fm_github_git_operation "$@")
      [ "$operation" != forbidden ] || { echo "error: routed Git command contains a forbidden credential or transport override" >&2; return 1; }
      if [ "$operation" = network ] || [ "$operation" = push ]; then
        target_repository=$(fm_github_git_network_repository "$@") || {
          echo "error: routed Git network target is not the configured HTTPS parent or selected-profile fork" >&2
          return 1
        }
        if [ "$operation" = push ]; then
          fm_github_preflight write "$target_repository" || return 1
        else
          fm_github_preflight read "$target_repository" || return 1
        fi
      fi
      if ! command "$FM_GITHUB_GIT_BINARY" "$@" 2>/dev/null; then
        echo "error: routed Git command failed for profile $FM_GITHUB_PROFILE_ID" >&2
        return 1
      fi
      ;;
    gh|gh-axi)
      operation=$(fm_github_gh_operation "$@")
      [ "$operation" != forbidden ] || { echo "error: routed GitHub authentication mutation, unsafe repository mutation, API escape, or token display is forbidden" >&2; return 1; }
      fm_github_validate_gh_resource "$@" || {
        echo "error: routed GitHub command targets a repository outside the configured parent or selected-profile fork" >&2
        return 1
      }
      case "$operation" in
        local|helper) ;;
        create) fm_github_preflight_login || return 1 ;;
        write)
          if [ "${1:-}" = pr ] && [ "${2:-}" = create ] && [ -n "$FM_GITHUB_FORK_OWNER" ]; then
            fm_github_preflight read || return 1
            fm_github_preflight write "github.com/$FM_GITHUB_FORK_OWNER/${FM_GITHUB_REPOSITORY##*/}" || return 1
          else
            fm_github_preflight write || return 1
          fi
          ;;
        *) fm_github_preflight read || return 1 ;;
      esac
      github_binary=$FM_GITHUB_GH_BINARY
      [ "${tool##*/}" != gh-axi ] || github_binary=$FM_GITHUB_GH_AXI_BINARY
      if ! command "$github_binary" "$@" 2>/dev/null; then
        echo "error: routed GitHub command failed for profile $FM_GITHUB_PROFILE_ID" >&2
        return 1
      fi
      ;;
    *)
      fm_github_preflight read || return 1
      command "$tool" "$@"
      ;;
  esac
}

fm_github_no_mistakes_context_file() {
  local destination=$1
  [ "$FM_GITHUB_MODE" = strict ] || return 1
  umask 077
  fm_github_node - "$destination" "$FM_GITHUB_GH_BINARY" "$FM_GITHUB_GIT_BINARY" "$FM_GITHUB_GH_CONFIG_DIR" "$FM_GITHUB_EXPECTED_LOGIN" "$FM_GITHUB_COMMIT_NAME" "$FM_GITHUB_COMMIT_EMAIL" "$FM_GITHUB_PROFILE_ID" <<'NODE'
const fs = require("node:fs");
const [destination, gh, git, config, login, name, email, label] = process.argv.slice(2);
const value = {
  version: 1,
  gh_path: gh,
  git_path: git,
  gh_config_dir: config,
  host: "github.com",
  expected_login: login,
  git_protocol: "https",
  credential_helper: "gh",
  commit_author: {name, email},
  label,
};
fs.writeFileSync(destination, JSON.stringify(value, null, 2) + "\n", {mode: 0o600});
NODE
}
