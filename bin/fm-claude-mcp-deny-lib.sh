#!/usr/bin/env bash
# fm-claude-mcp-deny-lib.sh - shared parsing for config/claude-denied-mcp-servers,
# sourced by bin/fm-spawn.sh and bin/fm-control.sh.
#
# docs/configuration.md "Claude worker MCP server denylist" owns the file format
# and operator contract; bin/fm-spawn.sh's header owns the launch substitution.

# fm_claude_denied_mcp_servers_json <config-dir>: print the settings JSON
# fragment `,"deniedMcpServers":[{"serverName":"<name>"},...]`, empty when the
# file is absent or lists nothing. Non-zero with the reason on stderr when the
# file or an entry is invalid. Entries are restricted to characters that need no
# JSON or shell quoting, so the fragment is safe to splice into the launch's
# single-quoted --settings argument.
fm_claude_denied_mcp_servers_json() {
  local config=$1 file line entries='' present
  file=$config/claude-denied-mcp-servers
  present=$(perl -MErrno=ENOENT -e '
    if (lstat $ARGV[0]) { print 1 }
    elsif ($! == ENOENT) { print 0 }
    else { die "error: cannot inspect config/claude-denied-mcp-servers: $!\n" }
  ' -- "$file") || return 1
  [ "$present" = 1 ] || return 0
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo "error: config/claude-denied-mcp-servers must be a readable regular file" >&2
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    case "$line" in
    '' | '#'*) continue ;;
    esac
    if [ -n "${line//[A-Za-z0-9_.:-]/}" ]; then
      echo "error: config/claude-denied-mcp-servers has a malformed entry '$line'; expected one MCP server name per line using only letters, digits, _ . : and - (blank lines and # comment lines are allowed)" >&2
      return 1
    fi
    entries="${entries:+$entries,}{\"serverName\":\"$line\"}"
  done <"$file" || {
    echo "error: cannot read config/claude-denied-mcp-servers" >&2
    return 1
  }
  [ -z "$entries" ] || printf ',"deniedMcpServers":[%s]' "$entries"
}
