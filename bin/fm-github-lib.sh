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
FM_GITHUB_ALLOW_UNREGISTERED_PROJECT=${FM_GITHUB_ALLOW_UNREGISTERED_PROJECT:-0}
FM_GITHUB_CLONE_CAPABILITY=${FM_GITHUB_CLONE_CAPABILITY:-}
FM_GITHUB_CLONE_ROOT=${FM_GITHUB_CLONE_ROOT:-}
FM_GITHUB_NO_MISTAKES_BINARY=${FM_GITHUB_NO_MISTAKES_BINARY:-}
FM_GITHUB_INVOCATION_ENDPOINT=${FM_GITHUB_INVOCATION_ENDPOINT:-}
FM_GITHUB_INVOCATION_BROKER_PID=${FM_GITHUB_INVOCATION_BROKER_PID:-}
FM_GITHUB_INVOCATION_BROKER_IDENTITY=${FM_GITHUB_INVOCATION_BROKER_IDENTITY:-}

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
  local config_path config_dir
  config_path=$(fm_github_config_path)
  config_dir=${config_path%/*}
  [ -e "$config_path" ] || [ -L "$config_path" ] || [ -L "$config_dir" ] || { [ -e "$config_dir" ] && [ ! -d "$config_dir" ]; }
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

fm_github_resolve_no_mistakes_binary() {
  local candidate output line key value
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    case "$candidate" in
      "$(fm_github_home)/state/.github-routing-path/"*) continue ;;
    esac
    output=$(fm_github_node "$(fm_github_lib_dir)/fm-github-config.mjs" canonicalize-executable \
      --basename no-mistakes --path "$candidate" 2>/dev/null) || continue
    while IFS= read -r line || [ -n "$line" ]; do
      key=${line%%$'\t'*}
      value=${line#*$'\t'}
      if [ "$key" = executable ] && [ "$line" != "$key" ]; then
        printf '%s\n' "$value"
        return 0
      fi
    done <<< "$output"
  done < <(type -a -p no-mistakes 2>/dev/null | awk '!seen[$0]++')
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
  [ "$FM_GITHUB_ALLOW_UNREGISTERED_PROJECT" != 1 ] || args+=(--allow-unregistered-project)
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

fm_github_file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}

fm_github_path_shim_body() {
  local action=$1 home=$2 executable=$3 quoted_home quoted_executable
  quoted_home=$(fm_github_shell_quote "$home")
  quoted_executable=$(fm_github_shell_quote "$executable")
  printf '#!/usr/bin/env bash\nset -eu\nexec %s %s --home %s -- "$@"\n' \
    "$quoted_executable" "$action" "$quoted_home"
}

fm_github_path_shims_valid() {
  local directory=$1 home=$2 executable=$3 name action expected
  [ -d "$directory" ] && [ ! -L "$directory" ] && [ "$(fm_github_file_mode "$directory")" = 500 ] || return 1
  for name in git gh gh-axi no-mistakes; do
    case "$name" in
      git) action=child-git ;;
      gh) action=child-gh ;;
      gh-axi) action=child-gh-axi ;;
      no-mistakes) action=child-no-mistakes ;;
    esac
    [ -f "$directory/$name" ] && [ ! -L "$directory/$name" ] \
      && [ "$(fm_github_file_mode "$directory/$name")" = 500 ] || return 1
    expected=$(fm_github_path_shim_body "$action" "$home" "$executable") || return 1
    printf '%s\n' "$expected" | cmp -s - "$directory/$name" || return 1
  done
}

fm_github_process_identity() {
  local pid=$1
  ps -o lstart= -p "$pid" 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

fm_github_path_identity() {
  if [ "$(uname)" = Darwin ]; then
    stat -f '%d:%i' "$1" 2>/dev/null
  else
    stat -c '%d:%i' "$1" 2>/dev/null
  fi
}

fm_github_lock_stale() {
  local lock=$1 version pid recorded owner_tmp extra current lock_dir
  [ -f "$lock" ] && [ ! -L "$lock" ] && [ "$(fm_github_file_mode "$lock")" = 600 ] || return 1
  {
    IFS= read -r version
    IFS= read -r pid
    IFS= read -r recorded
    IFS= read -r owner_tmp
    ! IFS= read -r extra
  } < "$lock" || return 1
  [ "$version" = fm-github-lock-v1 ] || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$recorded" ] || return 1
  lock_dir=${lock%/*}
  case "$owner_tmp" in "$lock_dir"/.lock-owner.*) ;; *) return 1 ;; esac
  current=$(fm_github_process_identity "$pid" || true)
  if [ -z "$current" ] || [ "$current" != "$recorded" ]; then
    FM_GITHUB_STALE_LOCK_OWNER_TMP=$owner_tmp
    return 0
  fi
  return 1
}

fm_github_lock_acquire() {
  local lock=$1 attempts=${2:-100} owner_tmp identity pid count=0 lock_identity stale_identity stale_tmp
  owner_tmp=$(mktemp "${lock%/*}/.lock-owner.XXXXXX") || return 1
  fm_github_node -e 'require("node:fs").writeFileSync(process.argv[1], `${process.ppid}\n`)' "$owner_tmp" \
    || { rm -f "$owner_tmp" 2>/dev/null || true; return 1; }
  IFS= read -r pid < "$owner_tmp" || { rm -f "$owner_tmp" 2>/dev/null || true; return 1; }
  identity=$(fm_github_process_identity "$pid") || { rm -f "$owner_tmp" 2>/dev/null || true; return 1; }
  printf '%s\n%s\n%s\n%s\n' fm-github-lock-v1 "$pid" "$identity" "$owner_tmp" > "$owner_tmp" \
    || { rm -f "$owner_tmp" 2>/dev/null || true; return 1; }
  chmod 0600 "$owner_tmp" || { rm -f "$owner_tmp" 2>/dev/null || true; return 1; }
  while [ "$count" -lt "$attempts" ]; do
    if ln "$owner_tmp" "$lock" 2>/dev/null; then
      lock_identity=$(fm_github_path_identity "$lock") || { rm -f "$lock" "$owner_tmp" 2>/dev/null || true; return 1; }
      rm -f "$owner_tmp" || { rm -f "$lock" 2>/dev/null || true; return 1; }
      FM_GITHUB_LOCK_PATH=$lock
      FM_GITHUB_LOCK_IDENTITY=$lock_identity
      export FM_GITHUB_LOCK_PATH FM_GITHUB_LOCK_IDENTITY
      return 0
    fi
    FM_GITHUB_STALE_LOCK_OWNER_TMP=
    if fm_github_lock_stale "$lock"; then
      stale_identity=$(fm_github_path_identity "$lock") || { rm -f "$owner_tmp" 2>/dev/null || true; return 1; }
      stale_tmp=$FM_GITHUB_STALE_LOCK_OWNER_TMP
      [ "$(fm_github_path_identity "$lock" 2>/dev/null || true)" = "$stale_identity" ] || continue
      rm -f "$lock" 2>/dev/null || continue
      if [ -f "$stale_tmp" ] && [ ! -L "$stale_tmp" ] \
        && [ "$(fm_github_path_identity "$stale_tmp" 2>/dev/null || true)" = "$stale_identity" ]; then
        rm -f "$stale_tmp" 2>/dev/null || true
      fi
      continue
    fi
    count=$((count + 1))
    sleep 0.05
  done
  rm -f "$owner_tmp" 2>/dev/null || true
  return 1
}

fm_github_lock_release() {
  [ -n "${FM_GITHUB_LOCK_PATH:-}" ] && [ -n "${FM_GITHUB_LOCK_IDENTITY:-}" ] || return 1
  [ "$(fm_github_path_identity "$FM_GITHUB_LOCK_PATH" 2>/dev/null || true)" = "$FM_GITHUB_LOCK_IDENTITY" ] || return 1
  rm -f "$FM_GITHUB_LOCK_PATH" || return 1
  FM_GITHUB_LOCK_PATH=
  FM_GITHUB_LOCK_IDENTITY=
  export FM_GITHUB_LOCK_PATH FM_GITHUB_LOCK_IDENTITY
}

fm_github_run_with_capability() {
  local operation=$1 binary=$2 status
  shift 2
  if fm_github_node - "$operation" "$binary" "$FM_GITHUB_REPOSITORY" "$@" <<'NODE'
const net = require("node:net");
const {spawn, spawnSync} = require("node:child_process");
const [operation, binary, repository, ...args] = process.argv.slice(2);
const identity = spawnSync("/bin/ps", ["-o", "lstart=", "-p", String(process.pid)], {encoding: "utf8"}).stdout.trim();
if (!identity) process.exit(1);
let used = false;
let childPid = 0;
const processField = (field, pid) => spawnSync("/bin/ps", ["-o", `${field}=`, "-p", String(pid)], {encoding: "utf8"}).stdout.trim();
const isChildProcess = (pid) => {
  let current = pid;
  for (let count = 0; count < 12 && current > 0; count += 1) {
    if (current === childPid) return true;
    const parent = Number(processField("ppid", current));
    if (!Number.isSafeInteger(parent) || parent <= 0 || parent === current) return false;
    current = parent;
  }
  return false;
};
const server = net.createServer((connection) => {
  let input = "";
  connection.setEncoding("utf8");
  connection.on("data", (chunk) => {
    input += chunk;
    if (Buffer.byteLength(input, "utf8") > 4096) connection.destroy();
  });
  connection.on("end", () => {
    let request;
    try {
      request = JSON.parse(input);
    } catch {
      connection.end("deny\n");
      return;
    }
    const requesterPid = request?.pid;
    if (!used && request?.version === 1 && request.operation === operation
      && request.binary === binary && request.repository === repository
      && Number.isSafeInteger(requesterPid) && requesterPid > 0
      && request.identity === processField("lstart", requesterPid) && isChildProcess(requesterPid)) {
      used = true;
      connection.end("ok\n");
      server.close();
    } else {
      connection.end("deny\n");
    }
  });
});
const finish = (status) => {
  if (server.listening) server.close();
  process.exit(status);
};
server.on("error", () => finish(1));
server.listen({host: "127.0.0.1", port: 0, exclusive: true}, () => {
  const address = server.address();
  if (!address || typeof address === "string") return finish(1);
  const env = {...process.env,
    FM_GITHUB_INVOCATION_ENDPOINT: `127.0.0.1:${address.port}`,
    FM_GITHUB_INVOCATION_BROKER_PID: String(process.pid),
    FM_GITHUB_INVOCATION_BROKER_IDENTITY: identity};
  const child = spawn(binary, args, {stdio: "inherit", env});
  childPid = child.pid;
  child.on("error", () => finish(1));
  child.on("exit", (code, signal) => finish(signal ? 1 : (code ?? 1)));
});
NODE
  then
    status=0
  else
    status=$?
  fi
  return "$status"
}

fm_github_validate_capability() {
  local operation=$1 expected_binary=$2 endpoint=${FM_GITHUB_INVOCATION_ENDPOINT:-} port
  local pid=${FM_GITHUB_INVOCATION_BROKER_PID:-} identity=${FM_GITHUB_INVOCATION_BROKER_IDENTITY:-}
  local current ancestor found=0 count=0 response
  case "$endpoint" in 127.0.0.1:*) port=${endpoint#127.0.0.1:} ;; *) return 1 ;; esac
  case "$port" in ''|*[!0-9]*) return 1 ;; esac
  [ "$port" -ge 1 ] 2>/dev/null && [ "$port" -le 65535 ] 2>/dev/null || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$identity" ] || return 1
  ancestor=$PPID
  while [ "$count" -lt 12 ] && [ -n "$ancestor" ]; do
    if [ "$ancestor" = "$pid" ]; then found=1; break; fi
    ancestor=$(ps -o ppid= -p "$ancestor" 2>/dev/null | tr -d '[:space:]') || return 1
    count=$((count + 1))
  done
  [ "$found" -eq 1 ] || return 1
  current=$(fm_github_process_identity "$pid" || true)
  [ -n "$current" ] && [ "$current" = "$identity" ] || return 1
  response=$(fm_github_node - "$port" "$operation" "$expected_binary" "$FM_GITHUB_REPOSITORY" <<'NODE'
const net = require("node:net");
const {spawnSync} = require("node:child_process");
const [port, operation, binary, repository] = process.argv.slice(2);
let output = "";
const identity = spawnSync("/bin/ps", ["-o", "lstart=", "-p", String(process.pid)], {encoding: "utf8"}).stdout.trim();
if (!identity) process.exit(1);
const client = net.createConnection({host: "127.0.0.1", port: Number(port)}, () => {
  client.end(JSON.stringify({version: 1, operation, binary, repository, pid: process.pid, identity}));
});
client.setEncoding("utf8");
client.setTimeout(2000, () => client.destroy());
client.on("data", (chunk) => { output += chunk; });
client.on("error", () => process.exit(1));
client.on("close", () => process.stdout.write(output === "ok\n" ? output : ""));
NODE
  ) || return 1
  [ "$response" = ok ] || return 1
}

fm_github_install_path_shims() {
  local home state base directory executable lock tmp= name action
  home=$(cd "$(fm_github_home)" 2>/dev/null && pwd -P) || return 1
  state="$home/state"
  if [ ! -e "$state" ]; then
    mkdir -m 0700 "$state" 2>/dev/null || [ -d "$state" ] || return 1
  fi
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  base="$state/.github-routing-path"
  if [ ! -e "$base" ]; then
    mkdir -m 0700 "$base" 2>/dev/null || [ -d "$base" ] || return 1
  fi
  [ -d "$base" ] && [ ! -L "$base" ] || return 1
  directory="$base/context-v1"
  executable="$(fm_github_lib_dir)/fm-github-exec.sh"
  if fm_github_path_shims_valid "$directory" "$home" "$executable"; then
    printf '%s\n' "$directory"
    return 0
  fi
  [ ! -e "$directory" ] && [ ! -L "$directory" ] || return 1
  lock="$base/.install.lock"
  fm_github_lock_acquire "$lock" 100 || return 1
  if fm_github_path_shims_valid "$directory" "$home" "$executable"; then
    fm_github_lock_release || return 1
    printf '%s\n' "$directory"
    return 0
  fi
  tmp=$(mktemp -d "$base/.context-v1.XXXXXX") || { fm_github_lock_release 2>/dev/null || true; return 1; }
  trap '[ -z "${tmp:-}" ] || { chmod 0700 "$tmp" 2>/dev/null || true; rm -rf -- "$tmp" 2>/dev/null || true; }; fm_github_lock_release 2>/dev/null || true' EXIT HUP INT TERM
  for name in git gh gh-axi no-mistakes; do
    case "$name" in
      git) action=child-git ;;
      gh) action=child-gh ;;
      gh-axi) action=child-gh-axi ;;
      no-mistakes) action=child-no-mistakes ;;
    esac
    fm_github_path_shim_body "$action" "$home" "$executable" > "$tmp/$name" || return 1
    chmod 0500 "$tmp/$name" || return 1
  done
  mv "$tmp" "$directory" || return 1
  tmp=
  chmod 0500 "$directory" || return 1
  fm_github_lock_release || return 1
  trap - EXIT HUP INT TERM
  fm_github_path_shims_valid "$directory" "$home" "$executable" || return 1
  printf '%s\n' "$directory"
}

fm_github_activate() {
  local project=${1:-} repository=${2:-} required_profile=${3:-} old_path helper shim_dir selected_path inherited_project_path
  inherited_project_path=${FM_GITHUB_PROJECT_PATH:-}
  fm_github_resolve "$project" "$repository" "$required_profile" || return 1
  [ "$FM_GITHUB_MODE" = strict ] || return 0
  old_path=${PATH:-/usr/bin:/bin}
  FM_GITHUB_NO_MISTAKES_BINARY=$(fm_github_resolve_no_mistakes_binary) || {
    echo "error: canonical no-mistakes command is unavailable for strict GitHub routing" >&2
    return 1
  }
  fm_github_unset_ambient
  shim_dir=$(fm_github_install_path_shims) || {
    echo "error: cannot install authoritative GitHub routing context" >&2
    return 1
  }
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
  fm_github_add_git_config fetch.recurseSubmodules false
  fm_github_add_git_config submodule.recurse false
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
  export FM_GITHUB_ALLOW_UNREGISTERED_PROJECT FM_GITHUB_NO_MISTAKES_BINARY
}

fm_github_unsafe_git_key() {
  local key context=${2:-command}
  key=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$key" in
    credential.*|http.*|include.*|includeif.*|url.*|protocol.*|ssh.*|alias.*|core.sshcommand|core.askpass|core.gitproxy|core.editor|core.hookspath|core.fsmonitor|core.pager|pager.*|sequence.editor|interactive.difffilter|diff.external|difftool.*.cmd|filter.*|merge.*.driver|gpg.*|fetch.recursesubmodules|submodule.recurse|submodule.*.url|submodule.*.update|remote.*.pushurl|remote.*.gh-resolved|remote.*.proxy|remote.*.proxyauthmethod|remote.*.uploadpack|remote.*.receivepack)
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

fm_github_git_command_name() {
  local arg expect_value=0
  for arg in "$@"; do
    if [ "$expect_value" -eq 1 ]; then expect_value=0; continue; fi
    case "$arg" in
      -C|-c) expect_value=1 ;;
      -c*|--no-pager|--paginate|-p|--literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--icase-pathspecs) ;;
      -*) return 1 ;;
      *) printf '%s\n' "$arg"; return ;;
    esac
  done
  return 1
}

fm_github_git_commit_identity_args_allowed() {
  local arg command_seen=0
  for arg in "$@"; do
    if [ "$command_seen" -eq 0 ]; then
      [ "$arg" != commit ] || command_seen=1
      continue
    fi
    case "$arg" in
      --author|--author=*|--reset-author|--amend|-C|-C?*|-c|-c?*|--reuse-message|--reuse-message=*|--reedit-message|--reedit-message=*) return 1 ;;
    esac
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
  if actual=$(fm_github_repository_toplevel "$PWD" 2>/dev/null); then
    [ -n "$configured" ] && fm_github_same_repository_copy "$actual" "$configured" || return 1
    printf '%s\n' "$actual"
    return
  fi
  printf '%s\n' "$configured"
}

fm_github_validate_repository_path() {
  local repo_path=$1 keys key urls raw
  [ -n "$repo_path" ] && [ -d "$repo_path" ] || return 0
  fm_github_validate_local_config "$repo_path" || return 1
  keys=$("$FM_GITHUB_GIT_BINARY" -C "$repo_path" config --name-only --get-regexp '^remote\..*\.url$' 2>/dev/null || true)
  while IFS= read -r key || [ -n "$key" ]; do
    [ -n "$key" ] || continue
    urls=$("$FM_GITHUB_GIT_BINARY" -C "$repo_path" config --get-all "$key" 2>/dev/null || true)
    while IFS= read -r raw || [ -n "$raw" ]; do
      [ -n "$raw" ] || continue
      fm_github_repository_allowed "$raw" >/dev/null || {
        echo "error: repository remote is not the configured HTTPS parent or selected-profile fork" >&2
        return 1
      }
    done <<< "$urls"
  done <<< "$keys"
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

fm_github_gh_option_kind() {
  local family=$1 subcommand=$2 option=$3
  case "$option" in
    --repo|-R) printf repo; return ;;
    --org|--user|--env|--repos)
      case "$family" in secret|variable|ruleset) printf reject; return ;; esac
      ;;
    --owner|-o)
      case "$family" in
        attestation) printf owner; return ;;
        secret|variable|ruleset) printf reject; return ;;
      esac
      ;;
    --hostname)
      case "$family" in attestation) printf host; return ;; esac
      ;;
    --template|-p)
      case "$family:$subcommand" in
        repo:create) printf repo ;;
        ruleset:list|ruleset:view|release:create) printf flag ;;
        *) printf data ;;
      esac
      return
      ;;
    --source)
      if [ "$family" = repo ] && [ "$subcommand" = list ]; then printf flag; else printf data; fi
      return
      ;;
    --branch-repo)
      if [ "$family" = issue ] && [ "$subcommand" = develop ]; then printf repo; else printf unknown; fi
      return
      ;;
    --head|-H)
      if [ "$family" = pr ] && [ "$subcommand" = create ]; then printf head; else printf data; fi
      return
      ;;
    --add-blocked-by|--add-blocking|--add-sub-issue|--parent|--remove-blocked-by|--remove-blocking|--remove-sub-issue)
      if [ "$family" = issue ] && [ "$subcommand" = edit ]; then printf issue; else printf unknown; fi
      return
      ;;
    --blocked-by|--blocking)
      if [ "$family" = issue ] && [ "$subcommand" = create ]; then printf issue; else printf unknown; fi
      return
      ;;
    --duplicate-of)
      if [ "$family" = issue ] && [ "$subcommand" = close ]; then printf issue; else printf unknown; fi
      return
      ;;
    --signer-repo)
      if [ "$family" = attestation ] && [ "$subcommand" = verify ]; then printf repo; else printf unknown; fi
      return
      ;;
    --signer-workflow|--tuf-url)
      if [ "$family" = attestation ]; then printf reject; else printf unknown; fi
      return
      ;;
    --app|--archive|--assignee|--attempt|--author|--author-email|--base|--body|--body-file|--branch|--bundle|--cert-identity|--cert-identity-regex|--cert-oidc-issuer|--color|--comment|--commit|--created|--custom-trusted-root|--description|--digest-alg|--dir|--discussion-category|--env-file|--event|--exclude|--field|--format|--gitignore|--homepage|--interval|--job|--jq|--key|--label|--language|--license|--limit|--lock-reason|--match-head-commit|--mention|--milestone|--name|--notes|--notes-file|--notes-start-tag|--order|--output|--pattern|--predicate-type|--project|--raw-field|--reason|--recover|--ref|--remote|--remove-assignee|--remove-label|--remove-project|--remove-reviewer|--reviewer|--search|--signer-digest|--source-digest|--source-ref|--state|--status|--subject|--tag|--target|--team|--title|--topic|--tuf-root|--type|--upstream-remote-name|--visibility|--workflow|--add-assignee|--add-label|--add-project|--add-reviewer|--size|--sort)
      printf data; return
      ;;
    --json)
      if [ "$family" = workflow ] && [ "$subcommand" = run ]; then printf flag; else printf data; fi
      return
      ;;
    --admin|--all|--approve|--archived|--auto|--bundle-from-oci|--checkout|--cleanup-tag|--clobber|--clone|--comments|--compact|--confirm|--conflict-status|--create-if-none|--debug|--default|--delete-branch|--delete-last|--deny-self-hosted-runners|--detach|--disable-auto|--disable-issues|--disable-wiki|--draft|--dry-run|--edit-last|--editor|--exclude-drafts|--exclude-pre-releases|--exit-status|--fail-fast|--fail-on-no-commits|--failed|--fill|--fill-first|--fill-verbose|--force|--fork|--generate-notes|--help|--include-all-branches|--internal|--latest|--list|--log|--log-failed|--merge|--name-only|--no-archived|--no-forks|--no-maintainer-edit|--no-public-good|--no-repos-selected|--no-source|--no-store|--no-upstream|--notes-from-tag|--parents|--patch|--prerelease|--private|--public|--push|--rebase|--recurse-submodules|--remove-milestone|--remove-parent|--remove-type|--required|--request-changes|--show-security-settings|--skip-existing|--squash|--succeed-on-no-caches|--undo|--verbose|--verify-only|--verify-tag|--watch|--web|--yaml|--yes)
      printf flag; return
      ;;
    -A|-B|-D|-F|-L|-O|-S|-T|-g|-h|-i|-j|-k|-n|-q|-t) printf data; return ;;
    -a)
      case "$family:$subcommand" in pr:review|workflow:list|run:list|cache:delete) printf flag ;; *) printf data ;; esac
      return
      ;;
    -b) printf data; return ;;
    -c)
      case "$family:$subcommand" in pr:status|pr:view|pr:review|issue:view|issue:develop|repo:create) printf flag ;; *) printf data ;; esac
      return
      ;;
    -d)
      case "$family:$subcommand" in pr:list|pr:close|pr:create|pr:merge|pr:revert|run:rerun|release:create) printf flag ;; *) printf data ;; esac
      return
      ;;
    -e)
      case "$family" in secret|variable) printf reject ;; *) case "$family:$subcommand" in pr:comment|pr:create|issue:comment|issue:create) printf flag ;; *) printf data ;; esac ;; esac
      return
      ;;
    -f)
      case "$family:$subcommand" in pr:checkout|pr:create|label:clone|label:create) printf flag ;; *) printf data ;; esac
      return
      ;;
    -l)
      case "$family:$subcommand" in issue:develop) printf flag ;; *) printf data ;; esac
      return
      ;;
    -m)
      case "$family:$subcommand" in pr:merge) printf flag ;; *) printf data ;; esac
      return
      ;;
    -r)
      case "$family" in secret|variable) printf reject ;; *) case "$family:$subcommand" in pr:merge|pr:review) printf flag ;; *) printf data ;; esac ;; esac
      return
      ;;
    -s)
      case "$family:$subcommand" in pr:merge) printf flag ;; *) printf data ;; esac
      return
      ;;
    -u)
      case "$family" in secret) printf reject ;; *) printf data ;; esac
      return
      ;;
    -v)
      case "$family:$subcommand" in run:view) printf flag ;; *) printf data ;; esac
      return
      ;;
    -w)
      case "$family:$subcommand" in run:list) printf data ;; *) printf flag ;; esac
      return
      ;;
    -y) printf flag; return ;;
  esac
  printf unknown
}

fm_github_validate_gh_value() {
  local kind=$1 value=$2 canonical owner
  case "$kind" in
    data|flag) return 0 ;;
    repo)
      canonical=$(fm_github_repository_allowed "$value") || return 1
      fm_github_set_gh_target_repository "$canonical" || return 1
      FM_GITHUB_GH_EXPLICIT_REPOSITORY=1
      ;;
    owner)
      fm_github_owner_allowed "$value" || return 1
      FM_GITHUB_GH_EXPLICIT_REPOSITORY=1
      ;;
    head)
      case "$value" in
        *:*) owner=${value%%:*}; fm_github_owner_allowed "$owner" ;;
        *) return 0 ;;
      esac
      ;;
    issue)
      case "$value" in
        https://github.com/*)
          canonical=$(fm_github_repository_allowed "$value") || return 1
          fm_github_set_gh_target_repository "$canonical"
          ;;
        *) return 0 ;;
      esac
      ;;
    host) [ "$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')" = github.com ] ;;
    *) return 1 ;;
  esac
}

fm_github_validate_gh_positional() {
  local family=$1 subcommand=$2 position=$3 value=$4 canonical
  case "$family:$subcommand:$position" in
    repo:create:1|repo:clone:1|repo:view:1|label:clone:1|issue:transfer:2)
      canonical=$(fm_github_repository_allowed "$value") || return 1
      fm_github_set_gh_target_repository "$canonical" || return 1
      FM_GITHUB_GH_EXPLICIT_REPOSITORY=1
      ;;
    repo:list:1)
      fm_github_owner_allowed "$value" || return 1
      FM_GITHUB_GH_EXPLICIT_REPOSITORY=1
      ;;
    attestation:download:1|attestation:verify:1)
      case "$value" in oci://*) return 1 ;; esac
      ;;
  esac
  case "$family:$subcommand" in
    pr:checks|pr:checkout|pr:close|pr:comment|pr:diff|pr:edit|pr:lock|pr:merge|pr:ready|pr:reopen|pr:review|pr:revert|pr:unlock|pr:update-branch|pr:view|issue:close|issue:comment|issue:delete|issue:develop|issue:edit|issue:lock|issue:pin|issue:reopen|issue:transfer|issue:unlock|issue:unpin|issue:view)
      case "$value" in
        https://github.com/*)
          canonical=$(fm_github_repository_allowed "$value") || return 1
          fm_github_set_gh_target_repository "$canonical" || return 1
          FM_GITHUB_GH_EXPLICIT_REPOSITORY=1
          ;;
      esac
      ;;
  esac
}

fm_github_validate_gh_positionals_complete() {
  local family=$1 subcommand=$2 count=$3
  case "$family:$subcommand" in
    repo:create|label:clone|attestation:download|attestation:verify) [ "$count" -eq 1 ] ;;
    repo:clone) [ "$count" -ge 1 ] && [ "$count" -le 2 ] ;;
    repo:view|repo:list) [ "$count" -le 1 ] ;;
    pr:checks|pr:checkout|pr:close|pr:comment|pr:diff|pr:edit|pr:lock|pr:merge|pr:ready|pr:reopen|pr:review|pr:revert|pr:unlock|pr:update-branch|pr:view) [ "$count" -le 1 ] ;;
    issue:transfer) [ "$count" -eq 2 ] ;;
    *) return 0 ;;
  esac
}

fm_github_validate_gh_resource() {
  local family=${1:-} subcommand=${2:-} arg option value kind pending='' position=0
  FM_GITHUB_GH_TARGET_REPOSITORY=
  FM_GITHUB_GH_EXPLICIT_REPOSITORY=0
  [ -n "$family" ] && [ -n "$subcommand" ] && [ "$family" != api ] || return 1
  shift 2
  for arg in "$@"; do
    if [ -n "$pending" ]; then
      fm_github_validate_gh_value "$pending" "$arg" || return 1
      pending=
      continue
    fi
    case "$arg" in
      --) return 1 ;;
      --*=*)
        option=${arg%%=*}
        value=${arg#*=}
        kind=$(fm_github_gh_option_kind "$family" "$subcommand" "$option")
        case "$kind" in
          flag) case "$value" in true|false) ;; *) return 1 ;; esac ;;
          unknown|reject) return 1 ;;
          *) fm_github_validate_gh_value "$kind" "$value" || return 1 ;;
        esac
        ;;
      -R?*) fm_github_validate_gh_value repo "${arg#-R}" || return 1 ;;
      -H?*)
        kind=$(fm_github_gh_option_kind "$family" "$subcommand" -H)
        [ "$kind" != unknown ] && fm_github_validate_gh_value "$kind" "${arg#-H}" || return 1
        ;;
      -q?*|-L?*|-t?*|-b?*|-B?*|-F?*|-T?*|-D?*|-O?*|-S?*|-n?*) ;;
      -*)
        kind=$(fm_github_gh_option_kind "$family" "$subcommand" "$arg")
        case "$kind" in
          flag) ;;
          data|repo|owner|head|issue|host) pending=$kind ;;
          *) return 1 ;;
        esac
        ;;
      *)
        position=$((position + 1))
        fm_github_validate_gh_positional "$family" "$subcommand" "$position" "$arg" || return 1
        ;;
    esac
  done
  [ -z "$pending" ] || return 1
  fm_github_validate_gh_positionals_complete "$family" "$subcommand" "$position"
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

fm_github_validate_preregistration_command() {
  local tool=$1 repository=$2 expected_parent source destination parent canonical arg command_name
  shift 2
  case "${tool##*/}" in
    git)
      command_name=$(fm_github_git_command_name "$@") || return 1
      if [ "$command_name" != clone ]; then
        [ "$FM_GITHUB_ALLOW_UNREGISTERED_PROJECT" != 1 ]
        return
      fi
      case "$FM_GITHUB_CLONE_CAPABILITY" in
        project)
          [ "$FM_GITHUB_ALLOW_UNREGISTERED_PROJECT" = 1 ] || return 1
          expected_parent=$(cd "$(fm_github_home)/projects" 2>/dev/null && pwd -P) || return 1
          ;;
        secondmate)
          [ "$FM_GITHUB_ALLOW_UNREGISTERED_PROJECT" != 1 ] || return 1
          expected_parent=$(cd "$FM_GITHUB_CLONE_ROOT" 2>/dev/null && pwd -P) || return 1
          ;;
        gh-project)
          [ "$FM_GITHUB_ALLOW_UNREGISTERED_PROJECT" != 1 ] || return 1
          expected_parent=$(cd "$(fm_github_home)/projects" 2>/dev/null && pwd -P) || return 1
          ;;
        *) return 1 ;;
      esac
      [ -n "$FM_GITHUB_PROJECT" ] && [ ! -d "$repository" ] || return 1
      [ "${1:-}" = clone ] || return 1
      shift
      [ "${1:-}" != --quiet ] || shift
      [ "${1:-}" != -- ] || shift
      [ "$#" -eq 2 ] || return 1
      source=$1
      destination=$2
      canonical=$(fm_github_repository_allowed "$source") || return 1
      [ "$(printf '%s' "$canonical" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$FM_GITHUB_REPOSITORY" | tr '[:upper:]' '[:lower:]')" ] || return 1
      [ ! -e "$destination" ] && [ ! -L "$destination" ] || return 1
      parent=${destination%/*}
      [ "$parent" != "$destination" ] || parent=.
      parent=$(cd "$parent" 2>/dev/null && pwd -P) || return 1
      [ "$parent" = "$expected_parent" ] && [ "${destination##*/}" = "$FM_GITHUB_PROJECT" ]
      ;;
    gh|gh-axi)
      [ "$FM_GITHUB_ALLOW_UNREGISTERED_PROJECT" = 1 ] || return 0
      [ -n "$FM_GITHUB_PROJECT" ] && [ ! -d "$repository" ] || return 1
      [ "${1:-}" = repo ] && [ "${2:-}" = create ] || return 1
      fm_github_projects_cwd || return 1
      for arg in "$@"; do
        case "$arg" in --clone|--clone=*|--source|--source=*|--push|--push=*) return 1 ;; esac
      done
      ;;
    *) [ "$FM_GITHUB_ALLOW_UNREGISTERED_PROJECT" != 1 ] ;;
  esac
}

fm_github_validate_gh_clone_command() {
  local repository=$1 source=${2:-} destination=${3:-} expected_parent parent canonical
  [ "$#" -eq 3 ] && [ -n "$FM_GITHUB_PROJECT" ] && [ ! -d "$repository" ] || return 1
  fm_github_projects_cwd || return 1
  canonical=$(fm_github_repository_allowed "$source") || return 1
  [ "$(printf '%s' "$canonical" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$FM_GITHUB_REPOSITORY" | tr '[:upper:]' '[:lower:]')" ] || return 1
  expected_parent=$(cd "$(fm_github_home)/projects" 2>/dev/null && pwd -P) || return 1
  [ ! -e "$destination" ] && [ ! -L "$destination" ] || return 1
  parent=${destination%/*}
  [ "$parent" != "$destination" ] || parent=.
  parent=$(cd "$parent" 2>/dev/null && pwd -P) || return 1
  [ "$parent" = "$expected_parent" ] && [ "${destination##*/}" = "$FM_GITHUB_PROJECT" ]
}

fm_github_projects_cwd() {
  local projects cwd
  projects=$(cd "$(fm_github_home)/projects" 2>/dev/null && pwd -P) || return 1
  cwd=$(pwd -P) || return 1
  [ "$cwd" = "$projects" ]
}

fm_github_validate_internal_api() {
  local endpoint= method= field= query= owner= name= name_variable= pending= arg value key path canonical validation suffix number
  shift
  while [ "$#" -gt 0 ]; do
    arg=$1
    shift
    if [ -n "$pending" ]; then
      case "$pending" in
        method) method=$arg ;;
        host) [ "$arg" = github.com ] || return 1 ;;
        field) field=$arg ;;
        data) ;;
      esac
      pending=
      if [ -n "$field" ]; then
        key=${field%%=*}
        value=${field#*=}
        [ "$field" != "$key" ] || return 1
        case "$key" in
          query) query=$value ;;
          owner) owner=$value ;;
          name|repo) name=$value; name_variable=$key ;;
          first|last|after|before|endCursor|cursor) [ ${#value} -le 1024 ] || return 1 ;;
          *) return 1 ;;
        esac
        field=
      fi
      continue
    fi
    case "$arg" in
      --method|-X) pending=method ;;
      --method=*|-X?*) method=${arg#*=}; [ "$method" != "$arg" ] || method=${arg#-X} ;;
      --hostname) pending=host ;;
      --hostname=github.com) ;;
      -f|-F|--field|--raw-field) pending=field ;;
      -f?*|-F?*) field=${arg#??}; pending=field; set -- "$field" "$@" ;;
      --field=*|--raw-field=*) field=${arg#*=}; pending=field; set -- "$field" "$@" ;;
      --jq|--template|--cache) pending=data ;;
      --jq=*|--template=*|--cache=*) ;;
      --paginate|--slurp) ;;
      --) return 1 ;;
      -*) return 1 ;;
      *) [ -z "$endpoint" ] || return 1; endpoint=$arg ;;
    esac
  done
  [ -z "$pending" ] && [ -n "$endpoint" ] || return 1
  if [ "$endpoint" = graphql ]; then
    [ -z "$method" ] || [ "$method" = POST ] || return 1
    [ -n "$query" ] || return 1
    [ -n "$name_variable" ] || name_variable=name
    validation=$(fm_github_node "$(fm_github_lib_dir)/fm-github-config.mjs" validate-graphql-read \
      --query "$query" --name-variable "$name_variable" --owner "$owner" --name "$name" 2>/dev/null) || return 1
    owner=$(printf '%s\n' "$validation" | sed -n $'s/^owner\t//p')
    name=$(printf '%s\n' "$validation" | sed -n $'s/^name\t//p')
    [ -n "$owner" ] && [ -n "$name" ] || return 1
    canonical=$(fm_github_repository_allowed "github.com/$owner/$name") || return 1
    printf '%s\n' "$canonical"
    return
  fi
  [ -z "$query$owner$name" ] || return 1
  [ -z "$method" ] || [ "$method" = GET ] || return 1
  path=${endpoint#/}
  path=${path%%\?*}
  case "$path" in *%*|*//*|*/../*|*/./*) return 1 ;; esac
  case "$path" in repos/*/*/pulls/*/reviews|repos/*/*/pulls/*/comments) ;; *) return 1 ;; esac
  owner=${path#repos/}
  owner=${owner%%/*}
  name=${path#repos/$owner/}
  name=${name%%/*}
  suffix=${path#repos/$owner/$name/pulls/}
  number=${suffix%%/*}
  case "$number" in ''|*[!0-9]*) return 1 ;; esac
  case "$suffix" in "$number/reviews"|"$number/comments") ;; *) return 1 ;; esac
  case "$owner/$name" in '{owner}/{repo}') canonical=$FM_GITHUB_REPOSITORY ;; *)
    canonical=$(fm_github_repository_allowed "github.com/$owner/$name") || return 1
    ;;
  esac
  fm_github_repository_allowed "$canonical" >/dev/null || return 1
  printf '%s\n' "$canonical"
}

fm_github_internal_gh_api_command() {
  local project=$1 repository=$2 required_profile=$3 target_repository repo_path
  shift 3
  [ "${1:-}" = api ] || return 1
  fm_github_activate "$project" "$repository" "$required_profile" || return 1
  fm_github_validate_capability gh-axi-api "$FM_GITHUB_GH_AXI_BINARY" || return 1
  target_repository=$(fm_github_validate_internal_api "$@") || return 1
  repo_path=$(fm_github_actual_repository_path "${FM_GITHUB_PROJECT_PATH:-}") || {
    echo "error: current repository is not the configured project or task copy" >&2
    return 1
  }
  fm_github_validate_repository_path "$repo_path" || return 1
  fm_github_preflight read "$target_repository" || return 1
  if ! command "$FM_GITHUB_GH_BINARY" "$@" 2>/dev/null; then
    echo "error: routed GitHub command failed for profile $FM_GITHUB_PROFILE_ID" >&2
    return 1
  fi
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
  fm_github_validate_preregistration_command "$tool" "$repository" "$@" || {
    echo "error: pre-registration GitHub routing is limited to the configured project clone or repository creation" >&2
    return 1
  }
  local repo_path='' operation target_repository github_binary command_cwd command_repo command_name
  if [ -d "$repository" ]; then
    repo_path=$repository
  elif [ -n "${FM_GITHUB_PROJECT_PATH:-}" ] && [ -d "$FM_GITHUB_PROJECT_PATH" ]; then
    repo_path=$FM_GITHUB_PROJECT_PATH
  fi
  case "${tool##*/}" in
    git)
      operation=$(fm_github_git_operation "$@")
      [ "$operation" != forbidden ] || { echo "error: routed Git command is unsupported or contains a forbidden credential, identity, or transport override" >&2; return 1; }
      command_name=$(fm_github_git_command_name "$@") || return 1
      command_cwd=$(fm_github_git_effective_cwd "$@") || {
        echo "error: routed Git command has an invalid working directory" >&2
        return 1
      }
      if command_repo=$(fm_github_repository_toplevel "$command_cwd" 2>/dev/null); then
        case "$command_name" in
          clone|ls-remote) fm_github_validate_repository_path "${repo_path:-}" || return 1 ;;
          *)
            if [ -n "$repo_path" ] && ! fm_github_same_repository_copy "$command_repo" "$repo_path"; then
              echo "error: current repository is not the configured project or task copy" >&2
              return 1
            fi
            fm_github_validate_repository_path "$command_repo" || return 1
            ;;
        esac
      else
        fm_github_validate_repository_path "${repo_path:-}" || return 1
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
      if [ "$operation" = create ] && [ "${FM_GITHUB_ALLOW_UNREGISTERED_PROJECT:-}" != 1 ]; then
        echo "error: repository creation requires an authorized pre-registration project route" >&2
        return 1
      fi
      case "$operation" in
        local|helper) ;;
        *)
          fm_github_validate_gh_resource "$@" || {
            echo "error: routed GitHub command has an unsupported target grammar or targets outside the configured parent or selected-profile fork" >&2
            return 1
          }
          ;;
      esac
      case "$operation:${1:-}:${2:-}" in
        read:repo:clone)
          fm_github_validate_gh_clone_command "$repository" "${3:-}" "${4:-}" || {
            echo "error: routed GitHub clone requires the canonical project destination" >&2
            return 1
          }
          ;;
        *)
          case "$operation" in
        local|helper) ;;
        *)
          if [ "$operation" != create ] || ! fm_github_projects_cwd; then
            repo_path=$(fm_github_actual_repository_path "$repo_path") || {
              echo "error: current repository is not the configured project or task copy" >&2
              return 1
            }
          fi
          fm_github_validate_repository_path "${repo_path:-}" || return 1
          ;;
          esac
          ;;
      esac
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
      if [ "${tool##*/}" = gh-axi ]; then
        if [ "$operation" = create ] && [ "${FM_GITHUB_ALLOW_UNREGISTERED_PROJECT:-}" = 1 ]; then
          fm_github_run_with_capability gh-axi-preregister "$github_binary" "$@" 2>/dev/null || {
            echo "error: routed GitHub command failed for profile $FM_GITHUB_PROFILE_ID" >&2
            return 1
          }
        else
          fm_github_run_with_capability gh-axi-api "$github_binary" "$@" 2>/dev/null || {
            echo "error: routed GitHub command failed for profile $FM_GITHUB_PROFILE_ID" >&2
            return 1
          }
        fi
      elif [ "${1:-}" = repo ] && [ "${2:-}" = clone ]; then
        fm_github_run_with_capability gh-repo-clone "$github_binary" "$@" 2>/dev/null || {
          echo "error: routed GitHub command failed for profile $FM_GITHUB_PROFILE_ID" >&2
          return 1
        }
      elif ! command "$github_binary" "$@" 2>/dev/null; then
        echo "error: routed GitHub command failed for profile $FM_GITHUB_PROFILE_ID" >&2
        return 1
      fi
      ;;
    *)
      fm_github_validate_repository_path "${repo_path:-}" || return 1
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
