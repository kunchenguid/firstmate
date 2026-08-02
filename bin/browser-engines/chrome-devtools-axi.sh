# shellcheck shell=bash
# Source-only adapter facts for the public-light Chrome DevTools AXI tool.
# This adapter is deliberately non-owning in v1 and must not be used for reliable
# visible custody, authenticated sessions, personal profiles, or attach mode.

fm_browser_chrome_devtools_axi_available() {
  command -v chrome-devtools-axi >/dev/null 2>&1
}

fm_browser_chrome_devtools_axi_version() {
  chrome-devtools-axi --version 2>/dev/null | head -n 1
}

fm_browser_chrome_devtools_axi_refuse_owned_mode() {
  echo "error: chrome-devtools-axi is public-light only until pinned lifecycle verification passes" >&2
  return 1
}
