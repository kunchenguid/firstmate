# shellcheck shell=bash
# Source-only adapter facts for Firstmate's primary visible browser engine.
# bin/fm-browser.sh is the sole public lifecycle owner and intentionally refuses
# real browser launches in the disabled core until a verified engine stage lands.

fm_browser_agent_browser_available() {
  command -v agent-browser >/dev/null 2>&1
}

fm_browser_agent_browser_version() {
  agent-browser --version 2>/dev/null | head -n 1
}

fm_browser_agent_browser_refuse_real_launch() {
  echo "error: real agent-browser launch is disabled until the verified visible engine stage lands" >&2
  return 1
}
