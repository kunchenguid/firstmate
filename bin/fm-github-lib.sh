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

fm_github_default_config_path() {
  printf '%s\n' "$(fm_github_home)/config/github-accounts.json"
}

fm_github_config_path() {
  fm_github_default_config_path
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
  env -u NODE_OPTIONS -u NODE_PATH -u FM_CONFIG_OVERRIDE -u FM_GITHUB_CONFIG -u FM_GITHUB_CONFIG_PATH \
    "$node_binary" "$@"
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
    "$git_binary" -C "$repo_path" config --get remote.origin.url 2>/dev/null
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

fm_github_repository_bound_to_profile() {
  local repository=$1
  fm_github_node "$(fm_github_lib_dir)/fm-github-config.mjs" resolve \
    --repository "$repository" --profile "$FM_GITHUB_PROFILE_ID" >/dev/null
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
  fm_github_repository_bound_to_profile "$canonical" || return 1
  printf '%s\n' "$canonical"
}

fm_github_owner_allowed() {
  local owner=$1 parent fork
  case "$owner" in ''|[!A-Za-z0-9]*|*[!A-Za-z0-9-]*|*-|*--*) return 1 ;; esac
  parent=${FM_GITHUB_REPOSITORY#github.com/}
  parent=${parent%%/*}
  fork=$FM_GITHUB_FORK_OWNER
  if [ "$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$parent" | tr '[:upper:]' '[:lower:]')" ]; then
    [ -n "$fork" ] || return 1
    [ "$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$fork" | tr '[:upper:]' '[:lower:]')" ] || return 1
  fi
  fm_github_repository_bound_to_profile "github.com/$owner/${FM_GITHUB_REPOSITORY##*/}"
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
  unset FM_GITHUB_CONFIG FM_GITHUB_CONFIG_PATH FM_CONFIG_OVERRIDE
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
  local key context=${2:-command}
  key=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$key" in
    credential.*|http.*|include.*|includeif.*|url.*|protocol.*|ssh.*|alias.*|core.sshcommand|core.askpass|core.gitproxy|core.editor|core.hookspath|core.fsmonitor|core.pager|pager.*|sequence.editor|interactive.difffilter|diff.external|difftool.*.cmd|filter.*|merge.*.driver|gpg.*|remote.*.pushurl|remote.*.proxy|remote.*.proxyauthmethod|remote.*.uploadpack|remote.*.receivepack)
      return 0
      ;;
    remote.*.url|remote.pushdefault|branch.*.remote|branch.*.pushremote|user.name|user.email|user.useconfigonly)
      [ "$context" = command ] && return 0
      ;;
  esac
  return 1
}

fm_github_validate_local_config() {
  local repo_path=${1:-} scope output key worktree_config
  [ "$FM_GITHUB_MODE" = strict ] || return 0
  [ -n "$repo_path" ] && [ -d "$repo_path" ] || return 0
  for scope in --local --worktree; do
    if [ "$scope" = --worktree ]; then
      [ "$("$FM_GITHUB_GIT_BINARY" -C "$repo_path" config --local --get extensions.worktreeConfig 2>/dev/null || true)" = true ] || continue
      worktree_config=$("$FM_GITHUB_GIT_BINARY" -C "$repo_path" rev-parse --path-format=absolute --git-path config.worktree 2>/dev/null) || {
        echo "error: cannot inspect repository-controlled Git configuration for profile $FM_GITHUB_PROFILE_ID" >&2
        return 1
      }
      [ -f "$worktree_config" ] || continue
    fi
    if ! output=$("$FM_GITHUB_GIT_BINARY" -C "$repo_path" config "$scope" --name-only --list 2>/dev/null); then
      echo "error: cannot inspect repository-controlled Git configuration for profile $FM_GITHUB_PROFILE_ID" >&2
      return 1
    fi
    while IFS= read -r key || [ -n "$key" ]; do
      [ -n "$key" ] || continue
      if fm_github_unsafe_git_key "$key" repository; then
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

fm_github_git_config_is_read_only() {
  local arg command_seen=0 expect_value=0 positional=0 read_mode=0
  for arg in "$@"; do
    if [ "$command_seen" -eq 0 ]; then
      [ "$arg" != config ] || command_seen=1
      continue
    fi
    if [ "$expect_value" -eq 1 ]; then expect_value=0; continue; fi
    case "$arg" in
      --global|--system|--file|--file=*|--blob|--blob=*|--add|--replace-all|--unset|--unset-all|--rename-section|--remove-section|--edit)
        return 1
        ;;
      --get|--get-all|--get-regexp|--get-urlmatch|--list|-l|--name-only)
        read_mode=1
        ;;
      --type|--default|--comment-char|--comment-string)
        expect_value=1
        ;;
      --type=*|--default=*|--show-origin|--show-scope|--fixed-value|--includes|--local|--worktree|-z|--null)
        ;;
      -*) return 1 ;;
      *)
        positional=$((positional + 1))
        if [ "$positional" -eq 1 ] && fm_github_unsafe_git_key "${arg%%=*}"; then return 1; fi
        ;;
    esac
  done
  [ "$expect_value" -eq 0 ] || return 1
  [ "$read_mode" -eq 1 ] || [ "$positional" -le 1 ]
}

fm_github_git_operation() {
  local arg command_name='' next_is_config=0 next_is_value=0
  for arg in "$@"; do
    if [ "$next_is_value" -eq 1 ]; then next_is_value=0; continue; fi
    if [ "$next_is_config" -eq 1 ]; then
      next_is_config=0
      if fm_github_unsafe_git_key "${arg%%=*}"; then printf forbidden; return; fi
      continue
    fi
    case "$arg" in
      -c) next_is_config=1; continue ;;
      -c*)
        if fm_github_unsafe_git_key "${arg#-c}"; then printf forbidden; return; fi
        continue
        ;;
      -C) next_is_value=1; continue ;;
      --git-dir|--work-tree|--namespace|--exec-path|--config-env) printf forbidden; return ;;
      --git-dir=*|--work-tree=*|--namespace=*|--exec-path=*|--config-env=*) printf forbidden; return ;;
      --no-pager|--paginate|-p|--literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--icase-pathspecs) continue ;;
      --version|--help) printf local; return ;;
      -*) printf forbidden; return ;;
      *) command_name=$arg; break ;;
    esac
  done
  [ "$next_is_config" -eq 0 ] && [ "$next_is_value" -eq 0 ] || { printf forbidden; return; }
  case "$command_name" in
    credential|credential-*|submodule) printf forbidden ;;
    remote)
      if fm_github_git_remote_is_read_only "$@"; then printf local; else printf forbidden; fi
      ;;
    config)
      if fm_github_git_config_is_read_only "$@"; then printf local; else printf forbidden; fi
      ;;
    push) printf push ;;
    clone|fetch|pull|ls-remote) printf network ;;
    commit)
      if fm_github_git_commit_identity_args_allowed "$@"; then printf identity; else printf forbidden; fi
      ;;
    am|cherry-pick|commit-tree|merge|notes|rebase|revert|stash) printf identity ;;
    archive)
      for arg in "$@"; do case "$arg" in --remote|--remote=*|--exec|--exec=*) printf forbidden; return ;; esac; done
      printf local
      ;;
    add|annotate|apply|bisect|blame|branch|bundle|cat-file|check-attr|check-ignore|check-mailmap|check-ref-format|checkout|clean|column|commit-graph|count-objects|describe|diff|diff-files|diff-index|diff-tree|difftool|fast-export|for-each-ref|format-patch|fsck|gc|grep|hash-object|help|index-pack|init|log|ls-files|ls-tree|merge-base|merge-file|merge-index|merge-one-file|merge-tree|mktag|mktree|multi-pack-index|mv|name-rev|pack-objects|patch-id|range-diff|read-tree|reflog|replace|reset|restore|rev-list|rev-parse|rm|show|show-branch|show-index|show-ref|sparse-checkout|stage|status|stripspace|switch|symbolic-ref|tag|unpack-file|unpack-objects|update-index|update-ref|var|verify-commit|verify-pack|verify-tag|whatchanged|worktree|write-tree) printf local ;;
    *) printf forbidden ;;
  esac
}

fm_github_git_commit_identity_args_allowed() {
  local arg command_seen=0
  for arg in "$@"; do
    if [ "$command_seen" -eq 0 ]; then
      [ "$arg" != commit ] || command_seen=1
      continue
    fi
    case "$arg" in --author|--author=*|--reset-author) return 1 ;; esac
  done
}

fm_github_git_effective_cwd() {
  local cwd=$PWD arg expect_cwd=0 expect_value=0
  for arg in "$@"; do
    if [ "$expect_cwd" -eq 1 ]; then
      case "$arg" in /*) cwd=$arg ;; *) cwd=$cwd/$arg ;; esac
      cwd=$(cd "$cwd" 2>/dev/null && pwd -P) || return 1
      expect_cwd=0
      continue
    fi
    if [ "$expect_value" -eq 1 ]; then expect_value=0; continue; fi
    case "$arg" in
      -C) expect_cwd=1 ;;
      -c) expect_value=1 ;;
      -c*|--no-pager|--paginate|-p|--literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--icase-pathspecs) ;;
      -*) ;;
      *) break ;;
    esac
  done
  [ "$expect_cwd" -eq 0 ] && [ "$expect_value" -eq 0 ] || return 1
  printf '%s\n' "$cwd"
}

fm_github_repository_toplevel() {
  local directory=$1 top
  [ -d "$directory" ] || return 1
  top=$("$FM_GITHUB_GIT_BINARY" -C "$directory" rev-parse --show-toplevel 2>/dev/null) || return 1
  cd "$top" 2>/dev/null && pwd -P
}

fm_github_same_repository_copy() {
  local first=$1 second=$2 first_common second_common
  [ -d "$first" ] && [ -d "$second" ] || return 1
  first_common=$("$FM_GITHUB_GIT_BINARY" -C "$first" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  second_common=$("$FM_GITHUB_GIT_BINARY" -C "$second" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  first_common=$(cd "$first_common" 2>/dev/null && pwd -P) || return 1
  second_common=$(cd "$second_common" 2>/dev/null && pwd -P) || return 1
  [ "$first_common" = "$second_common" ]
}

fm_github_actual_repository_path() {
  local configured=${1:-} actual
  if [ -n "$configured" ] && actual=$(fm_github_repository_toplevel "$PWD" 2>/dev/null) \
    && fm_github_same_repository_copy "$actual" "$configured"; then
    printf '%s\n' "$actual"
  else
    printf '%s\n' "$configured"
  fi
}

fm_github_validate_repository_path() {
  local repo_path=$1 urls raw
  [ -n "$repo_path" ] && [ -d "$repo_path" ] || return 0
  fm_github_validate_local_config "$repo_path" || return 1
  urls=$("$FM_GITHUB_GIT_BINARY" -C "$repo_path" config --get-all remote.origin.url 2>/dev/null || true)
  while IFS= read -r raw || [ -n "$raw" ]; do
    [ -n "$raw" ] || continue
    fm_github_repository_allowed "$raw" >/dev/null || {
      echo "error: repository origin is not the configured HTTPS parent or selected-profile fork" >&2
      return 1
    }
  done <<< "$urls"
}

fm_github_git_config_value() {
  local cwd=$1 key=$2 value
  value=$("$FM_GITHUB_GIT_BINARY" -C "$cwd" config --get "$key" 2>/dev/null) || return 1
  value=${value%%$'\n'*}
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

fm_github_git_default_remote() {
  local cwd=$1 command=$2 branch remote
  branch=$("$FM_GITHUB_GIT_BINARY" -C "$cwd" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  if [ "$command" = push ]; then
    if [ -n "$branch" ] && remote=$(fm_github_git_config_value "$cwd" "branch.$branch.pushRemote"); then
      printf '%s\n' "$remote"
      return
    fi
    if remote=$(fm_github_git_config_value "$cwd" remote.pushDefault); then
      printf '%s\n' "$remote"
      return
    fi
  fi
  if [ -n "$branch" ] && remote=$(fm_github_git_config_value "$cwd" "branch.$branch.remote"); then
    printf '%s\n' "$remote"
    return
  fi
  printf '%s\n' origin
}

fm_github_git_network_repository() {
  local cwd command='' command_seen=0 expect_cwd=0 expect_global_value=0 expect_option_value=0 expect_clone_config=0 positionals=0 arg target='' raw urls canonical selected=''
  cwd=$(fm_github_git_effective_cwd "$@") || return 1
  for arg in "$@"; do
    if [ "$expect_cwd" -eq 1 ]; then expect_cwd=0; continue; fi
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
    if [ "$expect_clone_config" -eq 1 ]; then
      expect_clone_config=0
      fm_github_unsafe_git_key "${arg%%=*}" && return 1
      continue
    fi
    if [ "$expect_option_value" -eq 1 ]; then expect_option_value=0; continue; fi
    if [ "$expect_option_value" -eq 2 ]; then
      [ -z "$target" ] || return 1
      target=$arg
      expect_option_value=0
      continue
    fi
    case "$command" in
      push)
        case "$arg" in
          --repo) expect_option_value=2 ;;
          --repo=*) [ -z "$target" ] || return 1; target=${arg#--repo=} ;;
          -o|--push-option) expect_option_value=1 ;;
          --receive-pack|--exec|--receive-pack=*|--exec=*) return 1 ;;
          -*) ;;
          *)
            positionals=$((positionals + 1))
            if [ "$positionals" -eq 1 ] && [ -z "$target" ]; then target=$arg; fi
            ;;
        esac
        ;;
      clone)
        case "$arg" in
          --config|-c) expect_clone_config=1 ;;
          --config=*)
            raw=${arg#--config=}
            fm_github_unsafe_git_key "${raw%%=*}" && return 1
            ;;
          --bundle-uri|--bundle-uri=*|--upload-pack|--upload-pack=*|-u|--recurse-submodules|--recurse-submodules=*|--recursive|--remote-submodules|--shallow-submodules|--also-filter-submodules) return 1 ;;
          -b|--branch|--depth|--shallow-since|--shallow-exclude|--reference|--reference-if-able|--separate-git-dir|--origin|-o|--template|--filter|--server-option|--revision) expect_option_value=1 ;;
          -*) ;;
          *)
            positionals=$((positionals + 1))
            if [ "$positionals" -eq 1 ]; then target=$arg; fi
            ;;
        esac
        ;;
      fetch|pull|ls-remote)
        case "$arg" in
          --upload-pack|--upload-pack=*|--recurse-submodules|--recurse-submodules=*) return 1 ;;
          --depth|--deepen|--shallow-since|--shallow-exclude|--server-option|--negotiation-tip|--jobs|-j|--filter|--sort) expect_option_value=1 ;;
          --all|--multiple) return 1 ;;
          -*) ;;
          *)
            positionals=$((positionals + 1))
            if [ "$positionals" -eq 1 ]; then target=$arg; fi
            ;;
        esac
        ;;
    esac
  done
  [ -n "$command" ] || return 1
  if [ "$expect_option_value" -eq 2 ]; then return 1; fi
  if [ "$expect_option_value" -eq 1 ] || [ "$expect_clone_config" -eq 1 ]; then return 1; fi
  if [ -z "$target" ]; then
    [ "$command" != clone ] && [ "$command" != ls-remote ] || return 1
    target=$(fm_github_git_default_remote "$cwd" "$command") || return 1
  fi
  case "$target" in
    https://*) raw=$target ;;
    *://*|*@*|*:*|/*) return 1 ;;
    *)
      case "$target" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
      urls=$("$FM_GITHUB_GIT_BINARY" -C "$cwd" config --get-all "remote.$target.url" 2>/dev/null) || return 1
      while IFS= read -r raw || [ -n "$raw" ]; do
        [ -n "$raw" ] || continue
        canonical=$(fm_github_repository_allowed "$raw") || return 1
        if [ -n "$selected" ] && [ "$(printf '%s' "$selected" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$canonical" | tr '[:upper:]' '[:lower:]')" ]; then
          return 1
        fi
        selected=$canonical
      done <<< "$urls"
      [ -n "$selected" ] || return 1
      printf '%s\n' "$selected"
      return 0
      ;;
  esac
  fm_github_repository_allowed "$raw"
}

fm_github_set_gh_target_repository() {
  local canonical=$1
  if [ -n "${FM_GITHUB_GH_TARGET_REPOSITORY:-}" ] \
    && [ "$(printf '%s' "$FM_GITHUB_GH_TARGET_REPOSITORY" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$canonical" | tr '[:upper:]' '[:lower:]')" ]; then
    return 1
  fi
  FM_GITHUB_GH_TARGET_REPOSITORY=$canonical
}

fm_github_gh_repo_option_kind() {
  local command=$1 option=$2
  case "$option" in
    --repo|-R|--branch|-b|--description|-d|--gitignore|-g|--homepage|-h|--jq|-q|--json|--language|-l|--license|-c|--limit|-L|--order|--remote|-r|--size|--sort|--source|-s|--team|-t|--template|--topic|--visibility)
      printf value
      ;;
    --add-readme|--archived|--clone|--disable-issues|--disable-wiki|--fork|--include-all-branches|--internal|--private|--public|--push|--web|-w|--no-archived|--no-forks|--no-source)
      printf flag
      ;;
    --*)
      case "$command" in
        view) case "$option" in --show-security-settings) printf flag; return ;; esac ;;
      esac
      printf unknown
      ;;
    -*) printf unknown ;;
    *) printf positional ;;
  esac
}

fm_github_validate_gh_repo_positionals() {
  local command=$2 arg kind expect_value='' positional=0 canonical candidate
  shift 2
  for arg in "$@"; do
    if [ -n "$expect_value" ]; then
      if [ "$expect_value" = --template ]; then
        canonical=$(fm_github_repository_allowed "$arg") || return 1
        fm_github_set_gh_target_repository "$canonical" || return 1
      fi
      expect_value=
      continue
    fi
    case "$arg" in
      --repo=*|-R?*) continue ;;
      --*=*)
        kind=$(fm_github_gh_repo_option_kind "$command" "${arg%%=*}")
        [ "$kind" != unknown ] || return 1
        if [ "${arg%%=*}" = --template ]; then
          candidate=${arg#*=}
          canonical=$(fm_github_repository_allowed "$candidate") || return 1
          fm_github_set_gh_target_repository "$canonical" || return 1
        fi
        continue
        ;;
    esac
    kind=$(fm_github_gh_repo_option_kind "$command" "$arg")
    case "$kind" in
      value) expect_value=$arg ;;
      flag) ;;
      unknown) return 1 ;;
      positional)
        positional=$((positional + 1))
        [ "$positional" -eq 1 ] || continue
        if [ "$command" = list ]; then
          fm_github_owner_allowed "$arg" || return 1
        else
          canonical=$(fm_github_repository_allowed "$arg") || return 1
          fm_github_set_gh_target_repository "$canonical" || return 1
        fi
        ;;
    esac
  done
  [ -z "$expect_value" ] || return 1
  case "$command" in create|clone) [ "$positional" -eq 1 ] ;; *) return 0 ;; esac
}

fm_github_validate_gh_issue_transfer() {
  local arg expect_value=0 positional=0 canonical
  shift 2
  for arg in "$@"; do
    if [ "$expect_value" -eq 1 ]; then expect_value=0; continue; fi
    case "$arg" in
      --repo|-R) expect_value=1 ;;
      --repo=*|-R?*|--confirm) ;;
      -*) return 1 ;;
      *)
        positional=$((positional + 1))
        if [ "$positional" -eq 2 ]; then
          canonical=$(fm_github_repository_allowed "$arg") || return 1
          fm_github_set_gh_target_repository "$canonical" || return 1
        fi
        ;;
    esac
  done
  [ "$expect_value" -eq 0 ] && [ "$positional" -eq 2 ]
}

fm_github_validate_gh_label_clone() {
  local arg expect_value=0 canonical
  shift 2
  for arg in "$@"; do
    if [ "$expect_value" -eq 1 ]; then expect_value=0; continue; fi
    case "$arg" in
      --repo|-R) expect_value=1 ;;
      --repo=*|-R?*|--force) ;;
      -*) return 1 ;;
      *)
        canonical=$(fm_github_repository_allowed "$arg") || return 1
        fm_github_set_gh_target_repository "$canonical" || return 1
        return 0
        ;;
    esac
  done
  return 1
}

fm_github_validate_gh_resource() {
  local first=${1:-} second=${2:-} arg expect_repo=0 expect_head=0 expect_owner=0 candidate canonical owner
  FM_GITHUB_GH_TARGET_REPOSITORY=
  [ "$first" != api ] || return 1
  for arg in "$@"; do
    if [ "$expect_repo" -eq 1 ]; then
      candidate=$arg
      expect_repo=0
    elif [ "$expect_head" -eq 1 ]; then
      case "$arg" in
        *:*) owner=${arg%%:*}; fm_github_owner_allowed "$owner" || return 1 ;;
      esac
      expect_head=0
      continue
    elif [ "$expect_owner" -eq 1 ]; then
      fm_github_owner_allowed "$arg" || return 1
      expect_owner=0
      continue
    else
      case "$arg" in
        --org|--org=*|--user|--user=*|--env|--env=*) return 1 ;;
        --repo|-R) expect_repo=1; continue ;;
        --repo=*) candidate=${arg#--repo=} ;;
        -R?*) candidate=${arg#-R} ;;
        --head|-H) expect_head=1; continue ;;
        --head=*|-H?*)
          candidate=${arg#*=}
          [ "$candidate" != "$arg" ] || candidate=${arg#-H}
          case "$candidate" in *:*) owner=${candidate%%:*}; fm_github_owner_allowed "$owner" || return 1 ;; esac
          continue
          ;;
        --owner) expect_owner=1; continue ;;
        --owner=*) fm_github_owner_allowed "${arg#--owner=}" || return 1; continue ;;
        oci://*) return 1 ;;
        https://github.com/*)
          canonical=$(fm_github_repository_allowed "$arg") || return 1
          fm_github_set_gh_target_repository "$canonical" || return 1
          continue
          ;;
        *) continue ;;
      esac
    fi
    canonical=$(fm_github_repository_allowed "$candidate") || return 1
    fm_github_set_gh_target_repository "$canonical" || return 1
  done
  [ "$expect_repo" -eq 0 ] && [ "$expect_head" -eq 0 ] && [ "$expect_owner" -eq 0 ] || return 1
  if [ "$first" = repo ]; then
    fm_github_validate_gh_repo_positionals "$@" || return 1
  elif [ "$first" = issue ] && [ "$second" = transfer ]; then
    fm_github_validate_gh_issue_transfer "$@" || return 1
  elif [ "$first" = label ] && [ "$second" = clone ]; then
    fm_github_validate_gh_label_clone "$@" || return 1
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
      case "$second" in
        checks|checkout|diff|list|status|view) printf read ;;
        close|comment|create|edit|lock|merge|ready|reopen|review|revert|unlock|update-branch) printf write ;;
        *) printf forbidden ;;
      esac
      ;;
    repo)
      case "$second" in create) printf create ;; view|list|clone) printf read ;; *) printf forbidden ;; esac
      ;;
    issue)
      case "$second" in list|status|view) printf read ;; close|comment|create|delete|develop|edit|lock|pin|reopen|transfer|unlock|unpin) printf write ;; *) printf forbidden ;; esac
      ;;
    secret|variable)
      case "$second" in list|get) printf read ;; set|delete|remove) printf write ;; *) printf forbidden ;; esac
      ;;
    workflow)
      case "$second" in list|view) printf read ;; run|enable|disable) printf write ;; *) printf forbidden ;; esac
      ;;
    run)
      case "$second" in list|view|watch|download) printf read ;; cancel|delete|rerun) printf write ;; *) printf forbidden ;; esac
      ;;
    release)
      case "$second" in list|view|download|verify|verify-asset) printf read ;; create|edit|delete|upload|delete-asset) printf write ;; *) printf forbidden ;; esac
      ;;
    cache)
      case "$second" in list) printf read ;; delete) printf write ;; *) printf forbidden ;; esac
      ;;
    label)
      case "$second" in list) printf read ;; clone|create|delete|edit) printf write ;; *) printf forbidden ;; esac
      ;;
    ruleset)
      case "$second" in check|list|view) printf read ;; *) printf forbidden ;; esac
      ;;
    attestation)
      case "$second" in download|trusted-root|verify) printf read ;; *) printf forbidden ;; esac
      ;;
    *) printf forbidden ;;
  esac
}

fm_github_context_command() {
  local project=$1 repository=$2 required_profile=$3 tool=$4
  shift 4
  if ! fm_github_enabled; then
    if [ -n "$required_profile" ]; then
      echo "error: the recorded GitHub account profile cannot be used because strict routing is no longer configured" >&2
      return 1
    fi
    command "$tool" "$@"
    return
  fi
  fm_github_activate "$project" "$repository" "$required_profile" || return 1
  local repo_path='' operation target_repository github_binary command_cwd command_repo
  if [ -d "$repository" ]; then
    repo_path=$repository
  elif [ -n "${FM_GITHUB_PROJECT_PATH:-}" ] && [ -d "$FM_GITHUB_PROJECT_PATH" ]; then
    repo_path=$FM_GITHUB_PROJECT_PATH
  fi
  repo_path=$(fm_github_actual_repository_path "$repo_path") || return 1
  fm_github_validate_repository_path "${repo_path:-}" || return 1
  case "${tool##*/}" in
    git)
      operation=$(fm_github_git_operation "$@")
      [ "$operation" != forbidden ] || { echo "error: routed Git command is unsupported or contains a forbidden credential, identity, or transport override" >&2; return 1; }
      command_cwd=$(fm_github_git_effective_cwd "$@") || {
        echo "error: routed Git command has an invalid working directory" >&2
        return 1
      }
      if command_repo=$(fm_github_repository_toplevel "$command_cwd" 2>/dev/null); then
        fm_github_validate_repository_path "$command_repo" || return 1
      fi
      if [ "$operation" = identity ]; then
        [ -n "$FM_GITHUB_COMMIT_NAME" ] && [ -n "$FM_GITHUB_COMMIT_EMAIL" ] || {
          echo "error: profile $FM_GITHUB_PROFILE_ID needs commit_identity for commit-producing Git commands" >&2
          return 1
        }
      fi
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
            fm_github_preflight write "${FM_GITHUB_GH_TARGET_REPOSITORY:-$FM_GITHUB_REPOSITORY}" || return 1
          fi
          ;;
        *) fm_github_preflight read "${FM_GITHUB_GH_TARGET_REPOSITORY:-$FM_GITHUB_REPOSITORY}" || return 1 ;;
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
