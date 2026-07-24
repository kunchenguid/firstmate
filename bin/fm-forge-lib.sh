#!/usr/bin/env bash
# Common forge operations for Firstmate.
#
# bin/fm-pr-lib.sh owns canonical pull-request identity and provenance.
# This file owns provider dispatch plus all Gitea configuration, authentication,
# HTTP, and response-validation mechanics. Callers must never implement their
# own Gitea request or token handling.

FM_FORGE_ERROR=
FM_FORGE_REPO_PROVIDER=
FM_FORGE_REPO_URL=
FM_FORGE_REPO_HOST=
FM_FORGE_REPO_PATH=
FM_FORGE_REPO_OWNER=
FM_FORGE_REPO_NAME=
FM_GITEA_BASE_URL=
FM_GITEA_AUTHORITY=
FM_GITEA_WEB_HOST=
FM_GITEA_ACCOUNT=
FM_GITEA_SSH_PORT=
FM_GITEA_SSH_ALIASES=
FM_GITEA_TOKEN=
# A caller may have exported a same-named ambient variable. Strip that export
# attribute before any private token is loaded so curl cannot inherit it.
export -n FM_GITEA_TOKEN 2>/dev/null || true
FM_GITEA_RESPONSE=

fm_forge_fail() {
  # shellcheck disable=SC2034  # Public error result consumed by sourcing callers.
  FM_FORGE_ERROR=$1
  return 1
}

fm_forge_port_valid() {
  local port=${1-}
  [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] || return 1
  [ "$port" -le 65535 ]
}

fm_forge_dns_or_ipv4_valid() {
  local host=${1-} label
  local -a labels
  [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || return 1
  case "$host" in
    .*|*.|*..*|*[!a-z0-9.-]*) return 1 ;;
  esac
  IFS=. read -ra labels <<< "$host"
  for label in "${labels[@]}"; do
    [ "${#label}" -ge 1 ] && [ "${#label}" -le 63 ] || return 1
    case "$label" in -*|*-) return 1 ;; esac
  done
}

fm_forge_authority_parse() {
  local authority=$1 host port=
  case "$authority" in
    *:*)
      host=${authority%:*}
      port=${authority##*:}
      [ -n "$host" ] && fm_forge_port_valid "$port" || return 1
      ;;
    *) host=$authority ;;
  esac
  fm_forge_dns_or_ipv4_valid "$host" || return 1
  FM_GITEA_AUTHORITY=$authority
  FM_GITEA_WEB_HOST=$host
}

fm_forge_config_file_valid() {
  local file=$1
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  [ "$(fm_pr_file_link_count "$file")" = 1 ] || return 1
  [ "$(fm_pr_file_mode "$file")" = 600 ]
}

# Load the single private Gitea account configured for this FirstMate home.
# docs/configuration.md owns the file schema and permission contract.
fm_forge_gitea_config_load() {
  # Never let an inherited xtrace setting print the later auth-config printf.
  set +x
  local config_dir=${FM_CONFIG_OVERRIDE:-${FM_HOME:-${FM_ROOT_OVERRIDE:-.}}/config}
  local config_file="$config_dir/gitea" token_file="$config_dir/gitea-token"
  local line key value base_count=0 account_count=0 port_count=0 token _extra
  FM_GITEA_BASE_URL=
  FM_GITEA_AUTHORITY=
  FM_GITEA_WEB_HOST=
  FM_GITEA_ACCOUNT=
  FM_GITEA_SSH_PORT=
  FM_GITEA_SSH_ALIASES=
  FM_GITEA_TOKEN=
  fm_forge_config_file_valid "$config_file" \
    || fm_forge_fail "Gitea configuration is unavailable or not mode 0600" || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) ;; *) fm_forge_fail "Gitea configuration is malformed"; return 1 ;; esac
    key=${line%%=*}
    value=${line#*=}
    [ -n "$value" ] || { fm_forge_fail "Gitea configuration is malformed"; return 1; }
    case "$key" in
      base_url)
        base_count=$((base_count + 1))
        [ "$base_count" -eq 1 ] || { fm_forge_fail "Gitea configuration is ambiguous"; return 1; }
        if [[ "$value" =~ ^(https?)://([^/]+)$ ]]; then
          fm_forge_authority_parse "${BASH_REMATCH[2]}" \
            || { fm_forge_fail "Gitea base URL is not canonical"; return 1; }
          FM_GITEA_BASE_URL=$value
        else
          fm_forge_fail "Gitea base URL is not canonical"
          return 1
        fi
        ;;
      account)
        account_count=$((account_count + 1))
        [ "$account_count" -eq 1 ] || { fm_forge_fail "Gitea configuration is ambiguous"; return 1; }
        [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$ ]] \
          || { fm_forge_fail "Gitea account is invalid"; return 1; }
        # shellcheck disable=SC2034  # Validated account identity is public client state.
        FM_GITEA_ACCOUNT=$value
        ;;
      ssh_alias)
        fm_forge_dns_or_ipv4_valid "$value" \
          || { fm_forge_fail "Gitea SSH alias is invalid"; return 1; }
        case $'\n'"$FM_GITEA_SSH_ALIASES"$'\n' in
          *$'\n'"$value"$'\n'*) fm_forge_fail "Gitea SSH alias is duplicated"; return 1 ;;
        esac
        FM_GITEA_SSH_ALIASES="${FM_GITEA_SSH_ALIASES}${FM_GITEA_SSH_ALIASES:+$'\n'}$value"
        ;;
      ssh_port)
        port_count=$((port_count + 1))
        if [ "$port_count" -ne 1 ] || ! fm_forge_port_valid "$value"; then
          fm_forge_fail "Gitea SSH port is invalid or duplicated"
          return 1
        fi
        FM_GITEA_SSH_PORT=$value
        ;;
      *) fm_forge_fail "Gitea configuration contains an unknown key"; return 1 ;;
    esac
  done < "$config_file"
  [ "$base_count" -eq 1 ] && [ "$account_count" -eq 1 ] \
    || { fm_forge_fail "Gitea configuration is incomplete"; return 1; }
  case $'\n'"$FM_GITEA_SSH_ALIASES"$'\n' in
    *$'\n'"$FM_GITEA_WEB_HOST"$'\n'*) ;;
    *) FM_GITEA_SSH_ALIASES="${FM_GITEA_SSH_ALIASES}${FM_GITEA_SSH_ALIASES:+$'\n'}$FM_GITEA_WEB_HOST" ;;
  esac
  fm_forge_config_file_valid "$token_file" \
    || { fm_forge_fail "Gitea token is unavailable or not mode 0600"; return 1; }
  exec 7< "$token_file" || { fm_forge_fail "Gitea token cannot be read"; return 1; }
  IFS= read -r token <&7 || { exec 7<&-; fm_forge_fail "Gitea token is empty"; return 1; }
  if IFS= read -r _extra <&7; then
    exec 7<&-
    fm_forge_fail "Gitea token file must contain exactly one line"
    return 1
  fi
  exec 7<&-
  [ "${#token}" -ge 1 ] && [ "${#token}" -le 4096 ] \
    && [[ "$token" =~ ^[A-Za-z0-9._~+-]+$ ]] \
    || { fm_forge_fail "Gitea token format is invalid"; return 1; }
  FM_GITEA_TOKEN=$token
}

fm_forge_repo_parts_valid() {
  local owner=$1 repo=$2
  [[ "$owner" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$ ]] || return 1
  [[ "$repo" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$ ]] || return 1
  [ "$owner" != . ] && [ "$owner" != .. ] && [ "$repo" != . ] && [ "$repo" != .. ]
}

fm_forge_gitea_ssh_alias_matches() {
  local wanted=$1 alias
  while IFS= read -r alias; do
    [ "$alias" = "$wanted" ] && return 0
  done <<< "$FM_GITEA_SSH_ALIASES"
  return 1
}

fm_forge_set_repo_identity() {
  local provider=$1 url=$2 host=$3 owner=$4 repo=$5
  FM_FORGE_REPO_PROVIDER=$provider
  FM_FORGE_REPO_URL=$url
  FM_FORGE_REPO_HOST=$host
  FM_FORGE_REPO_PATH="$owner/$repo"
  FM_FORGE_REPO_OWNER=$owner
  FM_FORGE_REPO_NAME=$repo
}

fm_forge_set_repo_path_identity() {
  local provider=$1 url=$2 host=$3 path=$4
  FM_FORGE_REPO_PROVIDER=$provider
  FM_FORGE_REPO_URL=$url
  FM_FORGE_REPO_HOST=$host
  FM_FORGE_REPO_PATH=$path
  FM_FORGE_REPO_OWNER=
  FM_FORGE_REPO_NAME=${path##*/}
}

# Parse a git origin into a provider-tagged repository identity.
# Gitea HTTPS/HTTP origins bind to base_url, and SSH origins bind only to the
# canonical host or configured ssh_alias/ssh_port values.
fm_forge_repo_url_parse() {
  local raw=$1 scheme authority owner repo path ssh_host ssh_port=
  FM_FORGE_REPO_PROVIDER=
  # shellcheck disable=SC2034  # Repository identity outputs consumed by sourcing callers.
  FM_FORGE_REPO_URL=
  # shellcheck disable=SC2034
  FM_FORGE_REPO_HOST=
  FM_FORGE_REPO_PATH=
  # shellcheck disable=SC2034
  FM_FORGE_REPO_OWNER=
  # shellcheck disable=SC2034
  FM_FORGE_REPO_NAME=

  if [[ "$raw" =~ ^https://github\.com/([^/]+)/([^/]+)$ ]]; then
    owner=${BASH_REMATCH[1]}; repo=${BASH_REMATCH[2]}; repo=${repo%.git}
    fm_forge_repo_parts_valid "$owner" "$repo" || return 1
    fm_forge_set_repo_identity github "https://github.com/$owner/$repo" github.com "$owner" "$repo"
    return 0
  fi
  if [[ "$raw" =~ ^(git@)?github\.com:([^/]+)/([^/]+)$ ]] \
    || [[ "$raw" =~ ^ssh://(git@)?github\.com/([^/]+)/([^/]+)$ ]]; then
    owner=${BASH_REMATCH[2]}; repo=${BASH_REMATCH[3]}; repo=${repo%.git}
    fm_forge_repo_parts_valid "$owner" "$repo" || return 1
    fm_forge_set_repo_identity github "https://github.com/$owner/$repo" github.com "$owner" "$repo"
    return 0
  fi

  # A missing Gitea config means this origin may still be GitLab or unknown.
  if fm_forge_gitea_config_load; then
    if [[ "$raw" =~ ^(https?)://([^/]+)/([^/]+)/([^/]+)$ ]]; then
      scheme=${BASH_REMATCH[1]}; authority=${BASH_REMATCH[2]}
      owner=${BASH_REMATCH[3]}; repo=${BASH_REMATCH[4]}; repo=${repo%.git}
      if [ "$scheme://$authority" = "$FM_GITEA_BASE_URL" ] \
        && fm_forge_repo_parts_valid "$owner" "$repo"; then
        fm_forge_set_repo_identity gitea "$FM_GITEA_BASE_URL/$owner/$repo" "$FM_GITEA_AUTHORITY" "$owner" "$repo"
        FM_GITEA_TOKEN=
        return 0
      fi
    fi
    if [[ "$raw" =~ ^ssh://([^@/]+@)?([^/:]+)(:([0-9]+))?/([^/]+)/([^/]+)$ ]]; then
      ssh_host=${BASH_REMATCH[2]}; ssh_port=${BASH_REMATCH[4]}
      owner=${BASH_REMATCH[5]}; repo=${BASH_REMATCH[6]}; repo=${repo%.git}
      if fm_forge_gitea_ssh_alias_matches "$ssh_host" \
        && fm_forge_repo_parts_valid "$owner" "$repo"; then
        if [ -n "$ssh_port" ]; then
          fm_forge_port_valid "$ssh_port" || { FM_GITEA_TOKEN=; return 1; }
          [ "$ssh_port" = "${FM_GITEA_SSH_PORT:-22}" ] || { FM_GITEA_TOKEN=; return 1; }
        fi
        fm_forge_set_repo_identity gitea "$FM_GITEA_BASE_URL/$owner/$repo" "$FM_GITEA_AUTHORITY" "$owner" "$repo"
        FM_GITEA_TOKEN=
        return 0
      fi
    elif [[ "$raw" =~ ^([^@/:]+@)?([^/:]+):([^/]+)/([^/]+)$ ]]; then
      ssh_host=${BASH_REMATCH[2]}
      owner=${BASH_REMATCH[3]}; repo=${BASH_REMATCH[4]}; repo=${repo%.git}
      if fm_forge_gitea_ssh_alias_matches "$ssh_host" \
        && fm_forge_repo_parts_valid "$owner" "$repo"; then
        fm_forge_set_repo_identity gitea "$FM_GITEA_BASE_URL/$owner/$repo" "$FM_GITEA_AUTHORITY" "$owner" "$repo"
        FM_GITEA_TOKEN=
        return 0
      fi
    fi
    FM_GITEA_TOKEN=
  fi

  if [[ "$raw" =~ ^https://gitlab\.com/(.+)$ ]]; then
    path=${BASH_REMATCH[1]}; path=${path%.git}
    fm_pr_gitlab_path_valid "$path" || return 1
    fm_forge_set_repo_path_identity gitlab "https://gitlab.com/$path" gitlab.com "$path"
    return 0
  fi
  if [[ "$raw" =~ ^(git@)?gitlab\.com:(.+)$ ]]; then
    path=${BASH_REMATCH[2]}; path=${path%.git}
    fm_pr_gitlab_path_valid "$path" || return 1
    fm_forge_set_repo_path_identity gitlab "https://gitlab.com/$path" gitlab.com "$path"
    return 0
  fi
  if [[ "$raw" =~ ^ssh://(git@)?gitlab\.com/(.+)$ ]]; then
    path=${BASH_REMATCH[2]}; path=${path%.git}
    fm_pr_gitlab_path_valid "$path" || return 1
    fm_forge_set_repo_path_identity gitlab "https://gitlab.com/$path" gitlab.com "$path"
    return 0
  fi
  return 1
}

fm_forge_repo_from_dir() {
  local dir=$1 origin
  origin=$(git -C "$dir" remote get-url origin 2>/dev/null) \
    || { fm_forge_fail "repository has no readable origin"; return 1; }
  fm_forge_repo_url_parse "$origin" \
    || { fm_forge_fail "repository origin is not a configured forge identity"; return 1; }
}

fm_forge_gitea_identity_bind() {
  local url=$1
  fm_pr_url_parse "$url" && [ "$FM_PR_PROVIDER" = gitea ] \
    || { fm_forge_fail "pull request is not a canonical Gitea identity"; return 1; }
  fm_forge_gitea_config_load || return 1
  [ "$FM_PR_URL" = "$FM_GITEA_BASE_URL/$FM_PR_PATH/pulls/$FM_PR_NUMBER" ] \
    && [ "$FM_PR_HOST" = "$FM_GITEA_AUTHORITY" ] \
    || { FM_GITEA_TOKEN=; fm_forge_fail "Gitea pull request host does not match private configuration"; return 1; }
  fm_forge_gitea_account_bind || return 1
  fm_forge_gitea_config_load || return 1
}

# Authenticated Gitea request. The token is delivered through curl's stdin
# config, never argv or environment. Raw curl/server errors are intentionally
# discarded so an untrusted response cannot reflect the credential into logs.
fm_forge_gitea_request() {
  local method=$1 endpoint=$2 body=${3-} expected=$4 curl_bin response body_file code rc=0 size
  local response_read_rc=0 token_reflected=false
  local tmp_dir
  FM_GITEA_RESPONSE=
  command -v jq >/dev/null 2>&1 \
    || { FM_GITEA_TOKEN=; fm_forge_fail "Gitea operations require jq"; return 1; }
  curl_bin=${FM_FORGE_CURL_BIN:-curl}
  command -v "$curl_bin" >/dev/null 2>&1 \
    || { FM_GITEA_TOKEN=; fm_forge_fail "Gitea operations require curl"; return 1; }
  umask 077
  tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-gitea.XXXXXX") \
    || { FM_GITEA_TOKEN=; fm_forge_fail "Gitea request workspace could not be created"; return 1; }
  response="$tmp_dir/response"
  body_file="$tmp_dir/body"
  : > "$response"
  if [ -n "$body" ]; then
    printf '%s' "$body" > "$body_file" || rc=1
    chmod 0600 "$body_file" || rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    if [ -n "$body" ]; then
      code=$(printf 'header = "Authorization: token %s"\n' "$FM_GITEA_TOKEN" \
        | "$curl_bin" --config - --silent --max-time 30 --max-filesize 1048576 \
          --proto '=http,https' --output "$response" --write-out '%{http_code}' \
          --request "$method" --header 'Content-Type: application/json' \
          --data-binary "@$body_file" --url "$FM_GITEA_BASE_URL/api/v1$endpoint" 2>/dev/null) || rc=$?
    else
      code=$(printf 'header = "Authorization: token %s"\n' "$FM_GITEA_TOKEN" \
        | "$curl_bin" --config - --silent --max-time 30 --max-filesize 1048576 \
          --proto '=http,https' --output "$response" --write-out '%{http_code}' \
          --request "$method" --url "$FM_GITEA_BASE_URL/api/v1$endpoint" 2>/dev/null) || rc=$?
    fi
  fi
  size=$(wc -c < "$response" 2>/dev/null) || size=1048577
  if [ "$size" -le 1048576 ]; then
    FM_GITEA_RESPONSE=$(cat "$response") || response_read_rc=1
    case "$FM_GITEA_RESPONSE" in
      *"$FM_GITEA_TOKEN"*) token_reflected=true ;;
    esac
  fi
  FM_GITEA_TOKEN=
  if [ "$rc" -ne 0 ]; then
    rm -rf "$tmp_dir"
    fm_forge_fail "Gitea request failed"
    return 1
  fi
  if [ "$token_reflected" = true ]; then
    FM_GITEA_RESPONSE=
    rm -rf "$tmp_dir"
    fm_forge_fail "Gitea response contained private authentication data"
    return 1
  fi
  case "$code" in
    401|403) rm -rf "$tmp_dir"; fm_forge_fail "Gitea authentication or authorization failed"; return 1 ;;
  esac
  case " $expected " in
    *" $code "*) ;;
    *) rm -rf "$tmp_dir"; fm_forge_fail "Gitea returned an unsupported HTTP response"; return 1 ;;
  esac
  [ "$size" -le 1048576 ] \
    || { rm -rf "$tmp_dir"; fm_forge_fail "Gitea response exceeded the safety limit"; return 1; }
  [ "$response_read_rc" -eq 0 ] \
    || { rm -rf "$tmp_dir"; fm_forge_fail "Gitea response could not be read"; return 1; }
  rm -rf "$tmp_dir"
}

fm_forge_gitea_account_bind() {
  local configured_account=$FM_GITEA_ACCOUNT
  fm_forge_gitea_request GET '/user' '' '200' || return 1
  jq -e --arg account "$configured_account" '
    type == "object" and
    (.login | type == "string") and
    .login == $account
  ' >/dev/null 2>&1 <<< "$FM_GITEA_RESPONSE" \
    || { fm_forge_fail "Gitea authenticated account does not match private configuration"; return 1; }
}

fm_forge_git_branch_valid() {
  [ "$#" -eq 1 ] && git check-ref-format --branch "$1" >/dev/null 2>&1
}

fm_forge_gitea_pr_json_valid() {
  local url=$1 number path=$2
  fm_pr_url_parse "$url" || return 1
  number=$FM_PR_NUMBER
  jq -e --arg url "$url" --arg path "$path" --argjson number "$number" '
    type == "object" and
    .number == $number and
    .html_url == $url and
    .base.repo.full_name == $path and
    (.state == "open" or .state == "closed") and
    (.merged | type == "boolean") and
    (.head.sha | type == "string") and
    (.head.sha | test("^[0-9a-f]{40}$|^[0-9a-f]{64}$"))
  ' >/dev/null 2>&1 <<< "$FM_GITEA_RESPONSE"
}

fm_forge_pr_head() {
  local url=$1 raw
  fm_pr_url_parse "$url" || { fm_forge_fail "pull request URL is invalid"; return 1; }
  case "$FM_PR_PROVIDER" in
    github)
      raw=$(gh pr view "$FM_PR_URL" --json headRefOid -q .headRefOid 2>/dev/null) \
        || { fm_forge_fail "GitHub pull request head lookup failed"; return 1; }
      fm_pr_head_valid "$raw" || { fm_forge_fail "GitHub returned a malformed pull request head"; return 1; }
      printf '%s\n' "$raw"
      ;;
    gitlab)
      fm_forge_fail "GitLab pull request head lookup is not available"
      return 1
      ;;
    gitea)
      fm_forge_gitea_identity_bind "$FM_PR_URL" || return 1
      fm_forge_gitea_request GET "/repos/$FM_PR_PATH/pulls/$FM_PR_NUMBER" '' '200' || return 1
      fm_forge_gitea_pr_json_valid "$FM_PR_URL" "$FM_PR_PATH" \
        || { fm_forge_fail "Gitea returned a malformed or cross-project pull request"; return 1; }
      jq -r '.head.sha' <<< "$FM_GITEA_RESPONSE"
      ;;
  esac
}

fm_forge_pr_state() {
  local url=$1 raw state
  fm_pr_url_parse "$url" || { fm_forge_fail "pull request URL is invalid"; return 1; }
  case "$FM_PR_PROVIDER" in
    github)
      raw=$(gh pr view "$FM_PR_URL" --json state -q .state 2>/dev/null) \
        || { fm_forge_fail "GitHub pull request lookup failed"; return 1; }
      case "$raw" in OPEN) state=open ;; CLOSED) state=closed ;; MERGED) state=merged ;; *) fm_forge_fail "GitHub returned an unsupported pull request state"; return 1 ;; esac
      ;;
    gitlab)
      raw=$(glab mr view "$FM_PR_NUMBER" -R "https://$FM_PR_HOST/$FM_PR_PATH" 2>/dev/null) \
        || { fm_forge_fail "GitLab merge request lookup failed"; return 1; }
      state=$(printf '%s\n' "$raw" | sed -n 's/^state:[[:space:]]*//p')
      [ "$(printf '%s\n' "$state" | awk 'END { print NR + 0 }')" -eq 1 ] \
        || { fm_forge_fail "GitLab returned an ambiguous merge request state"; return 1; }
      case "$state" in opened|open) state=open ;; closed) state=closed ;; merged) ;; *) fm_forge_fail "GitLab returned an unsupported merge request state"; return 1 ;; esac
      ;;
    gitea)
      fm_forge_gitea_identity_bind "$FM_PR_URL" || return 1
      fm_forge_gitea_request GET "/repos/$FM_PR_PATH/pulls/$FM_PR_NUMBER" '' '200' || return 1
      fm_forge_gitea_pr_json_valid "$FM_PR_URL" "$FM_PR_PATH" \
        || { fm_forge_fail "Gitea returned a malformed or cross-project pull request"; return 1; }
      if [ "$(jq -r '.merged' <<< "$FM_GITEA_RESPONSE")" = true ]; then state=merged; else state=$(jq -r '.state' <<< "$FM_GITEA_RESPONSE"); fi
      ;;
  esac
  printf '%s\n' "$state"
}

fm_forge_pr_merged() {
  local state
  state=$(fm_forge_pr_state "$1") || return 1
  [ "$state" = merged ] && printf '%s\n' merged
  return 0
}

fm_forge_gitea_pr_create() {
  local repo_dir=$1 head=$2 base=$3 title=$4 body=$5 payload url path
  fm_forge_repo_from_dir "$repo_dir" || return 1
  [ "$FM_FORGE_REPO_PROVIDER" = gitea ] || { fm_forge_fail "repository is not configured as Gitea"; return 1; }
  fm_forge_git_branch_valid "$head" && fm_forge_git_branch_valid "$base" \
    || { fm_forge_fail "Gitea pull request branches are invalid"; return 1; }
  [ -n "$title" ] && [ "${#title}" -le 4096 ] && [ "${#body}" -le 262144 ] \
    || { fm_forge_fail "Gitea pull request text is invalid"; return 1; }
  path=$FM_FORGE_REPO_PATH
  payload=$(jq -cn --arg head "$head" --arg base "$base" --arg title "$title" --arg body "$body" \
    '{head:$head,base:$base,title:$title,body:$body}') || { fm_forge_fail "Gitea request body could not be encoded"; return 1; }
  fm_forge_gitea_config_load || return 1
  fm_forge_gitea_account_bind || return 1
  fm_forge_gitea_config_load || return 1
  fm_forge_gitea_request POST "/repos/$path/pulls" "$payload" '201' || return 1
  url=$(jq -er '.html_url | strings' <<< "$FM_GITEA_RESPONSE" 2>/dev/null) \
    || { fm_forge_fail "Gitea returned a malformed pull request creation response"; return 1; }
  fm_pr_url_parse "$url" && [ "$FM_PR_PROVIDER" = gitea ] \
    && [ "$FM_PR_HOST" = "$FM_GITEA_AUTHORITY" ] && [ "$FM_PR_PATH" = "$path" ] \
    || { fm_forge_fail "Gitea returned a cross-host pull request identity"; return 1; }
  fm_forge_gitea_pr_json_valid "$url" "$path" \
    || { fm_forge_fail "Gitea returned a malformed pull request creation response"; return 1; }
  printf '%s\n' "$url"
}

fm_forge_gitea_collection() {
  local endpoint=$1 kind=$2 page=1 page_size=50 max_pages=20 count
  local tmp_dir pages_file
  umask 077
  tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-gitea-pages.XXXXXX") \
    || { fm_forge_fail "Gitea pagination workspace could not be created"; return 1; }
  pages_file="$tmp_dir/pages"
  : > "$pages_file"
  while [ "$page" -le "$max_pages" ]; do
    if [ "$page" -gt 1 ]; then
      fm_forge_gitea_config_load \
        || { rm -rf "$tmp_dir"; return 1; }
    fi
    fm_forge_gitea_request GET "$endpoint?page=$page&limit=$page_size" '' '200' \
      || { rm -rf "$tmp_dir"; return 1; }
    case "$kind" in
      reviews)
        jq -ce '
          type == "array" and all(.[];
            (.id | type == "number") and (.id >= 1) and
            (.state == "APPROVED" or .state == "PENDING" or .state == "COMMENT" or
             .state == "REQUEST_CHANGES" or .state == "REQUEST_REVIEW") and
            (.user.login | type == "string" and length > 0)
          )
        ' >/dev/null 2>&1 <<< "$FM_GITEA_RESPONSE" \
          || { rm -rf "$tmp_dir"; fm_forge_fail "Gitea returned malformed review data"; return 1; }
        ;;
      checks)
        jq -ce '
          type == "array" and all(.[];
            (.id | type == "number") and
            (.status == "success" or .status == "error" or .status == "failure" or
             .status == "pending" or .status == "warning") and
            (.context | type == "string")
          )
        ' >/dev/null 2>&1 <<< "$FM_GITEA_RESPONSE" \
          || { rm -rf "$tmp_dir"; fm_forge_fail "Gitea returned malformed check data"; return 1; }
        ;;
      *) rm -rf "$tmp_dir"; fm_forge_fail "Gitea collection type is unsupported"; return 1 ;;
    esac
    count=$(jq 'length' <<< "$FM_GITEA_RESPONSE") \
      || { rm -rf "$tmp_dir"; fm_forge_fail "Gitea collection could not be counted"; return 1; }
    printf '%s\n' "$FM_GITEA_RESPONSE" >> "$pages_file" \
      || { rm -rf "$tmp_dir"; fm_forge_fail "Gitea collection could not be recorded"; return 1; }
    if [ "$count" -lt "$page_size" ]; then
      FM_GITEA_RESPONSE=$(jq -cs 'add' "$pages_file") \
        || { rm -rf "$tmp_dir"; fm_forge_fail "Gitea collection could not be aggregated"; return 1; }
      rm -rf "$tmp_dir"
      return 0
    fi
    page=$((page + 1))
  done
  rm -rf "$tmp_dir"
  fm_forge_fail "Gitea collection exceeded the pagination safety limit"
  return 1
}

fm_forge_gitea_pr_reviews() {
  local url=$1
  fm_forge_gitea_identity_bind "$url" || return 1
  fm_forge_gitea_collection "/repos/$FM_PR_PATH/pulls/$FM_PR_NUMBER/reviews" reviews || return 1
  jq -c '[.[] | {id,state,user:.user.login,commit_id}]' <<< "$FM_GITEA_RESPONSE"
}

fm_forge_gitea_pr_checks() {
  local url=$1 head
  fm_forge_gitea_identity_bind "$url" || return 1
  head=$(fm_forge_pr_head "$url") || return 1
  # fm_forge_pr_head deliberately clears the token after its request.
  fm_forge_gitea_config_load || return 1
  fm_forge_gitea_collection "/repos/$FM_PR_PATH/commits/$head/statuses" checks || return 1
  jq -c '[.[] | {id,status,context,target_url,description}]' <<< "$FM_GITEA_RESPONSE"
}

fm_forge_pr_merge() {
  local url=$1 method=$2 delete_branch=${3:-false} payload state
  fm_pr_url_parse "$url" || { fm_forge_fail "pull request URL is invalid"; return 1; }
  case "$FM_PR_PROVIDER" in
    github) fm_forge_fail "GitHub merge dispatch remains owned by gh-axi"; return 1 ;;
    gitlab) fm_forge_fail "GitLab merge is not supported"; return 1 ;;
    gitea)
      case "$method" in squash|merge|rebase|rebase-merge) ;; *) fm_forge_fail "Gitea merge method is unsupported"; return 1 ;; esac
      case "$delete_branch" in true|false) ;; *) fm_forge_fail "Gitea delete-branch choice is invalid"; return 1 ;; esac
      fm_forge_gitea_identity_bind "$FM_PR_URL" || return 1
      payload=$(jq -cn --arg method "$method" --argjson delete "$delete_branch" \
        '{Do:$method,delete_branch_after_merge:$delete}') \
        || { fm_forge_fail "Gitea merge body could not be encoded"; return 1; }
      fm_forge_gitea_request POST "/repos/$FM_PR_PATH/pulls/$FM_PR_NUMBER/merge" "$payload" '200' || return 1
      # A 200 with an empty or version-specific body is not enough. Re-read the
      # canonical PR and require exact merged state before reporting success.
      state=$(fm_forge_pr_state "$FM_PR_URL") || return 1
      [ "$state" = merged ] || { fm_forge_fail "Gitea did not confirm the pull request as merged"; return 1; }
      ;;
  esac
}
