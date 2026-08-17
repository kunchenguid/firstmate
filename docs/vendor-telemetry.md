# Optional vendor telemetry

This repository cannot persistently configure the two vendor senders below.
The browser sender is launched by the user's MCP configuration.
The inspected shell's `PATH` has no `sentry-cli` executable, and this repository has no literal invocation.
This document records the verified settings and boundaries so the owner can apply the supported change in the launch environment.
Every command below was run on 2026-08-16.
Parenthetical status lines annotate an observed empty output or nonzero exit; they are not command output.

## Google Chrome DevTools MCP

The sender is `chrome-devtools-mcp`, launched underneath the fleet's `chrome-devtools-axi` wrapper.
The installed package, `chrome-devtools-mcp` 1.7.0, documents and reads:

```text
CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS=1
```

The following command started the installed package from a terminal with `CI` unset and only the supported opt-out variable set; its output confirms that the sender disabled collection:

```text
$ env -u CI CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS=1 timeout 5 node /Users/pedromuller/.npm/_npx/15c61037b1978c83/node_modules/chrome-devtools-mcp/build/src/bin/chrome-devtools-mcp.js
turning off usage statistics. process.env['CI'] || process.env['CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS'] is set.
chrome-devtools-mcp exposes content of the browser instance to the MCP clients allowing them to inspect,
debug, and modify any data in the browser or DevTools.
Avoid sharing sensitive or personal information that you do not want to share with MCP clients.
Performance tools may send trace URLs to the Google CrUX API to fetch real-user experience data. To disable, run with --no-performance-crux.
(terminated by `timeout` after five seconds; exit 124)
```

Set this exact key-value pair in the environment passed specifically to the MCP server:

```text
CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS=1
```

This is intentionally not added to the repository: the sender is launched from user-owned MCP configuration outside a disposable worktree.
Chrome browser metrics are a separate Google sender and are not changed by this setting.
Model-vendor tracking is a separate surface and was not changed.

## Sentry CLI

No `sentry-cli` executable was found on the inspected shell's `PATH`, and no literal repository invocation was found:

```text
$ command -v sentry-cli
(no output; exit 1)
$ which -a sentry-cli
sentry-cli not found
(exit 1)
$ rg -n --hidden --glob '!**/.git/**' --glob '!**/node_modules/**' --glob '!docs/vendor-telemetry.md' 'sentry-cli' .
(no output; exit 1)
```

The repository query excludes only this evidence record, which necessarily names the executable.
It would report any other literal reference, including an invocation.
These checks do not rule out a Sentry CLI installed outside `PATH`, or an invocation assembled dynamically, so they do not establish machine-wide absence.
No supported Sentry setting was changed because no local sender or configuration was found within the inspected scope.

## Existing fleet opt-outs

The current process environment confirms the previously approved opt-outs:

```text
$ env | rg '^(LAVISH_AXI_TELEMETRY|NO_MISTAKES_TELEMETRY)='
LAVISH_AXI_TELEMETRY=0
NO_MISTAKES_TELEMETRY=0
```
