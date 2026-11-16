#!/usr/bin/env bash
# fm-external-sandbox-lib.sh - the containment bin/fm-spawn.sh adds to a ship or
# scout whose task is marked external: launched with fm-spawn.sh --external, or
# on a project registered `trust=external` in data/projects.md
# (bin/fm-project-mode.sh --trust reads that token).
#
# docs/configuration.md "External workers" owns the operator contract and its
# measured limits; this file owns the settings block, the network allowlist,
# and the runtime-support refusal. bin/fm-spawn.sh's header owns the
# launch-flag mechanics.

# Command-line flags an external Claude launch adds: no MCP server loads, since
# a local server runs outside the sandbox with its own network access, and only
# user settings load beside the --settings file, since the checkout's own
# project and local settings can name hooks and helper commands that run
# outside the sandbox.
# shellcheck disable=SC2034 # Read by the sourcing caller.
FM_EXTERNAL_CLAUDE_FLAGS='--strict-mcp-config --setting-sources user'

# The hosts an external worker may reach: the GitHub hosts a worker reads code
# and pull requests from.
# shellcheck disable=SC2034 # Read by the sourcing caller.
FM_EXTERNAL_ALLOWED_DOMAINS='github.com
api.github.com
*.githubusercontent.com'

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

# fm_external_settings_json <keep-ai-trailers 0|1> <domains> <write-paths> <deny-write-paths> <unix-sockets> [<hooks-json>]:
# print the complete --settings object for an external Claude worker. It keeps
# the session keys every Claude worker carries (feedbackDrafts, and the
# attribution policy unless the home keeps AI trailers) and adds the sandbox:
# Bash runs only inside it, reads of credential files are refused for every
# tool, writes outside the working directories and the named write paths are
# refused for every tool, the named deny-write paths stay unwritable for every
# tool even inside a working directory or a write path, the network is closed
# to every host outside <domains>, and the account connectors and in-process
# web tools are off. <domains>, <write-paths>, <deny-write-paths>, and
# <unix-sockets> each hold one entry per line, every path absolute;
# <unix-sockets> names the only local sockets sandboxed commands may connect
# to, such as a delivery pipeline's daemon. <hooks-json> is an optional
# {"hooks": ...} object merged in, so the worker's own busy hooks load from
# this file. The launch adds FM_EXTERNAL_CLAUDE_FLAGS, because local MCP
# servers and project settings run outside the sandbox and only command-line
# flags turn them off.
fm_external_settings_json() {  # <keep-ai-trailers 0|1> <domains> <write-paths> <deny-write-paths> <unix-sockets> [<hooks-json>]
  local keep=$1 domains=$2 writes=$3 denies=$4 sockets=$5 hooks=${6:-'{}'}
  local domains_json writes_json denies_json sockets_json
  domains_json=$(printf '%s' "$domains" | jq -R . | jq -sc 'map(select(length > 0))') || return 1
  writes_json=$(printf '%s' "$writes" | jq -R . | jq -sc 'map(select(length > 0))') || return 1
  denies_json=$(printf '%s' "$denies" | jq -R . | jq -sc 'map(select(length > 0))') || return 1
  sockets_json=$(printf '%s' "$sockets" | jq -R . | jq -sc 'map(select(length > 0))') || return 1
  jq -nc --argjson keep "$keep" --argjson domains "$domains_json" \
    --argjson writes "$writes_json" --argjson denies "$denies_json" \
    --argjson sockets "$sockets_json" --argjson hooks "$hooks" '
    {feedbackDrafts: "off"}
    + (if $keep == 1 then {} else {attribution: {commit: "", pr: "", sessionUrl: false}} end)
    + $hooks
    + {
      disableClaudeAiConnectors: true,
      permissions: {
        blockWritesOutsideWorkingDirectories: true,
        deny: ([
          "WebFetch",
          "WebSearch",
          "Read(**/.env)",
          "Read(**/.env.*)",
          "Read(~/.ssh/**)",
          "Read(~/.aws/**)",
          "Read(~/.gnupg/**)",
          "Read(~/.netrc)",
          "Read(~/.git-credentials)",
          "Read(~/.config/git/credentials)",
          "Read(~/.config/gh/**)",
          "Read(~/.docker/config.json)",
          "Read(~/.npmrc)",
          "Read(~/.kube/config)",
          "Read(~/.config/gcloud/**)",
          "Read(~/.azure/**)"
        ] + [$denies[] | "Edit(/\(.))", "Edit(/\(.)/**)"])
      },
      sandbox: {
        enabled: true,
        failIfUnavailable: true,
        autoAllowBashIfSandboxed: true,
        allowUnsandboxedCommands: false,
        filesystem: ({allowWrite: $writes}
          + (if ($denies | length) > 0 then {denyWrite: $denies} else {} end)),
        network: ({allowedDomains: $domains, strictAllowlist: true}
          + (if ($sockets | length) > 0 then {allowUnixSockets: $sockets} else {} end))
      }
    }'
}
