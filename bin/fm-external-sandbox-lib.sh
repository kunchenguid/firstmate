#!/usr/bin/env bash
# fm-external-sandbox-lib.sh - the containment bin/fm-spawn.sh adds to a ship or
# scout whose task is marked external: launched with fm-spawn.sh --external, or
# on a project registered `trust=external` in data/projects.md
# (bin/fm-project-mode.sh --trust reads that token).
#
# docs/configuration.md "External workers" owns the operator contract and its
# measured limits; this file owns the settings block, the allowlist file
# parser, and the runtime-support refusal. bin/fm-spawn.sh's header owns the
# launch-flag mechanics.

# Command-line flags an external Claude launch adds: no MCP server loads, since
# a local server runs outside the sandbox with its own network access.
FM_EXTERNAL_CLAUDE_FLAGS='--strict-mcp-config'

# The allowlist an external worker gets when config/external-allowed-domains
# is absent: the GitHub hosts a worker reads code and pull requests from.
FM_EXTERNAL_DEFAULT_DOMAINS='github.com
api.github.com
*.githubusercontent.com'

# fm_external_domains <config-dir>: print the allowlist, one domain per line.
# An absent config/external-allowed-domains prints the default list; a file
# with no entries prints nothing, which closes the network completely.
# Non-zero with the reason on stderr when the file or an entry is invalid.
fm_external_domains() {
  local config=$1 file line present out=''
  file=$config/external-allowed-domains
  present=$(perl -MErrno=ENOENT -e '
    if (lstat $ARGV[0]) { print 1 }
    elsif ($! == ENOENT) { print 0 }
    else { die "error: cannot inspect config/external-allowed-domains: $!\n" }
  ' -- "$file") || return 1
  if [ "$present" != 1 ]; then
    printf '%s\n' "$FM_EXTERNAL_DEFAULT_DOMAINS"
    return 0
  fi
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo "error: config/external-allowed-domains must be a readable regular file" >&2
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    case "$line" in
    '' | '#'*) continue ;;
    esac
    # A host name, optionally led by "*." and optionally followed by ":<port>".
    if ! printf '%s' "$line" | grep -Eq '^(\*\.)?[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*(:[0-9]{1,5})?$'; then
      echo "error: config/external-allowed-domains has a malformed entry '$line'; expected one host name per line, optionally led by '*.' or followed by ':<port>' (blank lines and # comment lines are allowed)" >&2
      return 1
    fi
    out="$out$line"$'\n'
  done <"$file" || {
    echo "error: cannot read config/external-allowed-domains" >&2
    return 1
  }
  printf '%s' "$out"
}

# fm_external_check <harness> <raw-launch 0|1> [<backend>]: succeed when this
# launch can carry the external containment. Only the claude runtime has a
# verified settings sandbox, and only a Firstmate-built command line carries
# it, so every other runtime, a raw launch command, and the t3code backend
# (which starts the agent itself) refuse rather than start an external worker
# uncontained.
fm_external_check() {
  local harness=$1 raw=$2 backend=${3:-}
  if [ "$backend" = t3code ]; then
    echo "error: this task is marked external, but backend=t3code starts the agent itself and cannot carry the external worker sandbox; choose another backend" >&2
    return 1
  fi
  if [ "$raw" = 1 ]; then
    echo "error: this task is marked external, but a raw launch command cannot carry the external worker sandbox; launch the claude runtime instead" >&2
    return 1
  fi
  if [ "$harness" != claude ]; then
    echo "error: this task is marked external, but the $harness runtime has no verified external worker sandbox, so this launch is refused rather than running uncontained; launch the claude runtime instead" >&2
    return 1
  fi
  command -v jq >/dev/null 2>&1 || {
    echo "error: this task is marked external, and building its sandbox settings needs jq on PATH" >&2
    return 1
  }
}

# fm_external_settings_json <keep-ai-trailers 0|1> <domains> <write-paths> <unix-sockets>:
# print the complete --settings object for an external Claude worker. It keeps
# the session keys every Claude worker carries (feedbackDrafts, and the
# attribution policy unless the home keeps AI trailers) and adds the sandbox:
# Bash runs only inside it, reads of credential files are refused for every
# tool, writes outside the working directories and the named write paths are
# refused for every tool, the network is closed to every host outside
# <domains>, and the account connectors and in-process web tools are off.
# <domains>, <write-paths>, and <unix-sockets> each hold one entry per line;
# <unix-sockets> names the only local sockets sandboxed commands may connect
# to, such as a delivery pipeline's daemon. The launch adds
# FM_EXTERNAL_CLAUDE_FLAGS, because local MCP servers run outside the sandbox
# and only a command-line flag turns them all off.
fm_external_settings_json() {  # <keep-ai-trailers 0|1> <domains> <write-paths> <unix-sockets>
  local keep=$1 domains=$2 writes=$3 sockets=$4 domains_json writes_json sockets_json
  domains_json=$(printf '%s' "$domains" | jq -R . | jq -sc 'map(select(length > 0))') || return 1
  writes_json=$(printf '%s' "$writes" | jq -R . | jq -sc 'map(select(length > 0))') || return 1
  sockets_json=$(printf '%s' "$sockets" | jq -R . | jq -sc 'map(select(length > 0))') || return 1
  jq -nc --argjson keep "$keep" --argjson domains "$domains_json" \
    --argjson writes "$writes_json" --argjson sockets "$sockets_json" '
    {feedbackDrafts: "off"}
    + (if $keep == 1 then {} else {attribution: {commit: "", pr: "", sessionUrl: false}} end)
    + {
      disableClaudeAiConnectors: true,
      permissions: {
        blockWritesOutsideWorkingDirectories: true,
        deny: [
          "WebFetch",
          "WebSearch",
          "Read(**/.env)",
          "Read(**/.env.*)",
          "Read(~/.ssh/**)",
          "Read(~/.aws/**)",
          "Read(~/.gnupg/**)",
          "Read(~/.netrc)",
          "Read(~/.git-credentials)"
        ]
      },
      sandbox: {
        enabled: true,
        failIfUnavailable: true,
        autoAllowBashIfSandboxed: true,
        allowUnsandboxedCommands: false,
        filesystem: {allowWrite: $writes},
        network: ({allowedDomains: $domains, strictAllowlist: true}
          + (if ($sockets | length) > 0 then {allowUnixSockets: $sockets} else {} end))
      }
    }'
}
