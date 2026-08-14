# AXI toolchain verification

This record supports Firstmate's exact reviewed npm toolchain and stable browser transport guarantee.
The authoritative version registry and executable checks live in [`bin/fm-reviewed-toolchain.sh`](../../bin/fm-reviewed-toolchain.sh).
Operator behavior is documented in [`docs/configuration.md`](../configuration.md#toolchain).

## Browser component source review

Review date: 2026-08-14.

The selected package is `chrome-devtools-mcp@1.7.0`, published by the npm package named `chrome-devtools-mcp` from `ChromeDevTools/chrome-devtools-mcp` under Apache-2.0.
The authoritative GitHub release is `chrome-devtools-mcp-v1.7.0`, whose tag resolves to commit `774d78f5eef5e610407a0c92fa6ec5ed74b027e8`.
The release is not marked draft or prerelease.
The package requires Node `^20.19.0 || ^22.12.0 || >=23`.
The direct MCP execution entrypoint is `build/src/bin/chrome-devtools-mcp.js`.
The npm registry integrity is `sha512-6xFW7oiUxTxZuHcfyYBkKQtmttjCbfifKZMSEk5CV8H2FucvKweYiJr8CblddYHtYjA4C14K9VAs1r49906RBA==` and the registry SHA-1 is `b20e2ee77afb585e2e762535c37ca9336e7445a4`.
A fresh `npm pack --ignore-scripts chrome-devtools-mcp@1.7.0` produced the same SHA-512 integrity and SHA-1.

The package's MCP server uses standard input/output transport and exits when its client closes standard input.
It can launch Chrome or attach through browser URL, WebSocket endpoint, auto-connect, or a supplied user-data directory, so callers must continue to use isolated task-specific sessions unless attachment is explicitly intended.
The maintained chrome-devtools-axi path uses an isolated headless browser by default and adds mock-keychain and basic-password-store Chrome arguments.
The MCP client can inspect and modify all content exposed by the connected browser.
Google usage statistics are enabled by default and can be disabled with `--no-usage-statistics`, `CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS`, or `CI`.
Independent npm update checks are enabled by default and can be disabled with `CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS`.
Performance analysis may send trace URLs to the Google CrUX API unless `--no-performance-crux` is used.
The reviewed Firstmate integration changes package resolution only and does not silently attach to a browser, select a persistent profile, or alter these upstream privacy defaults.

Source-review commands and relevant exact output were:

```text
$ npm view chrome-devtools-mcp --json name version repository engines bin dist.integrity dist.shasum
{
  "name": "chrome-devtools-mcp",
  "version": "1.7.0",
  "repository": {"url":"git+https://github.com/ChromeDevTools/chrome-devtools-mcp.git","type":"git"},
  "engines": {"node":"^20.19.0 || ^22.12.0 || >=23"},
  "bin": {"chrome-devtools":"build/src/bin/chrome-devtools.js","chrome-devtools-mcp":"build/src/bin/chrome-devtools-mcp.js"},
  "dist.integrity": "sha512-6xFW7oiUxTxZuHcfyYBkKQtmttjCbfifKZMSEk5CV8H2FucvKweYiJr8CblddYHtYjA4C14K9VAs1r49906RBA==",
  "dist.shasum": "b20e2ee77afb585e2e762535c37ca9336e7445a4"
}

$ gh-axi api /repos/ChromeDevTools/chrome-devtools-mcp/git/ref/tags/chrome-devtools-mcp-v1.7.0
ref: refs/tags/chrome-devtools-mcp-v1.7.0
object:
  sha: 774d78f5eef5e610407a0c92fa6ec5ed74b027e8
  type: commit

$ gh-axi release list -R ChromeDevTools/chrome-devtools-mcp --limit 20
chrome-devtools-mcp-v1.7.0,"chrome-devtools-mcp: v1.7.0",no,no,4d ago

$ npm pack --ignore-scripts chrome-devtools-mcp@1.7.0
filename: chrome-devtools-mcp-1.7.0.tgz
shasum: b20e2ee77afb585e2e762535c37ca9336e7445a4
integrity: sha512-6xFW7oiUxTxZu[...]VAs1r49906RBA==
```

## Machine-local installation and transport proof

Verification date: 2026-08-14.
The machine used Node `v26.4.0` and npm `11.17.0`, satisfying the reviewed package's engine declaration.
Only the exact authorized browser package was changed globally.

```text
$ npm install -g chrome-devtools-mcp@1.7.0
added 1 package

$ npm prefix -g
/opt/homebrew

$ node "$(npm prefix -g)/lib/node_modules/chrome-devtools-mcp/build/src/bin/chrome-devtools-mcp.js" --version
1.7.0

$ bin/fm-reviewed-toolchain.sh check chrome-devtools-mcp
chrome-devtools-mcp@1.7.0
entrypoint=/opt/homebrew/lib/node_modules/chrome-devtools-mcp/build/src/bin/chrome-devtools-mcp.js
```

The displayed machine path is evidence from this host, not a shared-code constant.
Shared code derives the corresponding path from the active `npm prefix -g` value.

A task-specific session named `fm-axi-hardening-example` opened `https://example.com` with auto-connect off, no user-data directory, headless mode, usage statistics disabled, and update checks disabled.
A PATH-leading `npx` refusal shim recorded any invocation and would have failed the session.
The page opened successfully with title `Example Domain`, the npx invocation log remained empty, and `CHROME_DEVTOOLS_AXI_SESSION=fm-axi-hardening-example chrome-devtools-axi stop` returned `status: stopped`.
This proves the installed chrome-devtools-axi used the reviewed global MCP path rather than its floating npx fallback for that isolated session.

## Refresh procedure

A future pin change requires a new source review, an edit to the single registry in `bin/fm-reviewed-toolchain.sh`, updated executable regression evidence, a consent-gated exact install, and a refreshed isolated browser proof.
Do not replace this process with a latest-version floor, a vendor self-update command, or an unattended package-manager upgrade.
