#!/usr/bin/env bash
# fm-context-mode-webfetch-fix.sh - reapply Firstmate's narrow context-mode WebFetch compatibility patch.
#
# Usage:
#   fm-context-mode-webfetch-fix.sh [--claude-dir <directory>] [--check]
#
# The script resolves the context-mode marketplace checkout and active cache from
# Claude's plugin registry, validates both routing.mjs source shapes before it
# writes either, and applies only the claude.ai WebFetch allow-host boundary.
set -eu

CLAUDE_DIR=
CHECK_ONLY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --claude-dir)
      [ "$#" -ge 2 ] || {
        printf 'fm-context-mode-webfetch-fix.sh: --claude-dir requires a directory.\n' >&2
        exit 2
      }
      CLAUDE_DIR=$2
      shift 2
      ;;
    --check)
      CHECK_ONLY=1
      shift
      ;;
    --help|-h)
      sed -n '2,8{s/^# \{0,1\}//;p;}' "$0"
      exit 0
      ;;
    *)
      printf 'fm-context-mode-webfetch-fix.sh: unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

exec python3 - "$CLAUDE_DIR" "$CHECK_ONLY" <<'PY'
from __future__ import annotations

import json
import os
import sys
from pathlib import Path


HELPERS = '''// Hosts whose pages a plain HTTP fetch cannot materialize: they require the
// caller's authenticated session and/or render client-side. For these,
// ctx_fetch_and_index returns only the SPA shell, so redirecting WebFetch there
// does not protect context - it just makes the page unreadable. context-mode's
// own guidance already excludes SPA-rendered pages ("no headless browser").
// Setting CONTEXT_MODE_WEBFETCH_ALLOW_HOSTS deliberately widens this boundary
// to the comma-separated hosts selected by the operator.
const DEFAULT_WEBFETCH_ALLOW_HOSTS = ["claude.ai"];

function getWebFetchAllowHosts(env = process.env) {
  const raw = env.CONTEXT_MODE_WEBFETCH_ALLOW_HOSTS;
  if (typeof raw !== "string" || raw.trim() === "") return DEFAULT_WEBFETCH_ALLOW_HOSTS;
  const hosts = raw.split(",").map(h => h.trim().toLowerCase()).filter(Boolean);
  return hosts.length > 0 ? hosts : DEFAULT_WEBFETCH_ALLOW_HOSTS;
}

function isWebFetchAllowedHost(url, env = process.env) {
  if (typeof url !== "string" || url === "") return false;
  let host;
  try {
    host = new URL(url).hostname.toLowerCase();
  } catch {
    return false;
  }
  if (host === "") return false;
  return getWebFetchAllowHosts(env).some(
    allowed => host === allowed || host.endsWith(`.${allowed}`),
  );
}
'''

GET_WEB_FETCH_URL = '''function getWebFetchUrl(toolInput) {
  if (!toolInput || typeof toolInput !== "object") return "";
  if (typeof toolInput.url === "string") return toolInput.url;
  if (typeof toolInput.URL === "string") return toolInput.URL;
  if (typeof toolInput.Url === "string") return toolInput.Url;
  return "";
}'''

WEBFETCH_ANCHOR = '''  // ─── WebFetch: deny + redirect to sandbox ───
  if (canonical === "WebFetch") {
    const url = getWebFetchUrl(toolInput);
    return mcpRedirect({'''

WEBFETCH_INSERT = '''  // ─── WebFetch: deny + redirect to sandbox ───
  if (canonical === "WebFetch") {
    const url = getWebFetchUrl(toolInput);
    // Session-authenticated / client-rendered hosts: the sandbox fetcher can
    // only retrieve an empty shell for these, so redirecting protects no
    // context and instead makes the page unreadable. Let WebFetch through.
    if (isWebFetchAllowedHost(url)) return null;
    return mcpRedirect({'''


class PatchError(Exception):
    """A source file or plugin registry no longer matches the supported shape."""


def fail(message: str) -> None:
    raise PatchError(f"fm-context-mode-webfetch-fix.sh: {message}")


def resolve_paths(claude_dir: Path) -> list[Path]:
    plugins_dir = claude_dir / "plugins"
    marketplace = plugins_dir / "marketplaces" / "context-mode" / "hooks" / "core" / "routing.mjs"
    registry_path = plugins_dir / "installed_plugins.json"
    try:
        registry = json.loads(registry_path.read_text(encoding="utf-8"))
        installs = registry["plugins"]["context-mode@context-mode"]
    except (FileNotFoundError, OSError, json.JSONDecodeError, KeyError, TypeError) as exc:
        fail(f"cannot resolve the active context-mode cache from {registry_path}: {exc}")
    if not isinstance(installs, list) or len(installs) != 1:
        fail("expected exactly one active context-mode plugin registration")
    install_path = installs[0].get("installPath") if isinstance(installs[0], dict) else None
    if not isinstance(install_path, str) or install_path == "":
        fail("the active context-mode registration has no installPath")
    cache_root = plugins_dir / "cache" / "context-mode" / "context-mode"
    cache_install = Path(install_path).resolve()
    try:
        relative = cache_install.relative_to(cache_root.resolve())
    except ValueError:
        fail(f"active context-mode cache is outside {cache_root}: {cache_install}")
    if len(relative.parts) != 1:
        fail(f"active context-mode cache is not a version directory: {cache_install}")
    cache = cache_install / "hooks" / "core" / "routing.mjs"
    if marketplace == cache:
        fail("marketplace and active cache routing paths unexpectedly resolve to one file")
    return [marketplace, cache]


def patched_source(source: str, path: Path) -> tuple[str, bool]:
    applied = source.count(HELPERS) == 1 and source.count(WEBFETCH_INSERT) == 1
    touched = HELPERS in source or WEBFETCH_INSERT in source
    if touched:
        if not applied:
            fail(f"unsupported partial or drifted WebFetch patch in {path}")
        return source, False
    helper_anchor = f"{GET_WEB_FETCH_URL}\n\nfunction getCodexConfigDir("
    if source.count(helper_anchor) != 1:
        fail(f"expected WebFetch URL helper anchor exactly once in {path}")
    if source.count(WEBFETCH_ANCHOR) != 1:
        fail(f"expected WebFetch routing anchor exactly once in {path}")
    updated = source.replace(
        helper_anchor,
        f"{GET_WEB_FETCH_URL}\n\n{HELPERS}\nfunction getCodexConfigDir(",
        1,
    )
    updated = updated.replace(WEBFETCH_ANCHOR, WEBFETCH_INSERT, 1)
    if updated.count(HELPERS) != 1 or updated.count(WEBFETCH_INSERT) != 1:
        fail(f"internal patch construction failed for {path}")
    return updated, True


def main() -> int:
    supplied_dir, check_only_raw = sys.argv[1:]
    raw_dir = supplied_dir or os.environ.get("CLAUDE_CONFIG_DIR")
    claude_dir = Path(raw_dir).expanduser() if raw_dir else Path.home() / ".claude"
    try:
        targets = resolve_paths(claude_dir.resolve())
        planned: list[tuple[Path, str, bool]] = []
        for path in targets:
            try:
                source = path.read_text(encoding="utf-8")
            except (FileNotFoundError, OSError, UnicodeDecodeError) as exc:
                fail(f"cannot read {path}: {exc}")
            updated, changed = patched_source(source, path)
            planned.append((path, updated, changed))
        changed_paths = [path for path, _, changed in planned if changed]
        if check_only_raw == "1":
            if changed_paths:
                fail("WebFetch patch is absent from " + ", ".join(str(path) for path in changed_paths))
            print("context-mode WebFetch patch is present in both required copies")
            return 0
        for path, updated, changed in planned:
            if changed:
                path.write_text(updated, encoding="utf-8")
                print(f"applied context-mode WebFetch patch: {path}")
            else:
                print(f"context-mode WebFetch patch already applied: {path}")
        return 0
    except PatchError as exc:
        print(exc, file=sys.stderr)
        return 1


raise SystemExit(main())
PY
