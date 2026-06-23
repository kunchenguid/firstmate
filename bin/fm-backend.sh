#!/usr/bin/env bash
# Backend helpers for firstmate's visible crew runtime.
# Default backend is tmux. Set FM_BACKEND=orca, codex-app, or opencode-server via
# config/backend(.env) to use another visible crew backend.

fm_backend_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
}

fm_backend_name() {
  local root=${FM_ROOT:-$(fm_backend_root)} cfg line
  if [ -n "${FM_BACKEND:-}" ]; then
    echo "$FM_BACKEND"
    return 0
  fi
  if [ -f "$root/config/backend" ]; then
    cfg=$(tr -d '[:space:]' < "$root/config/backend" || true)
    [ -n "$cfg" ] && { echo "$cfg"; return 0; }
  fi
  if [ -f "$root/config/backend.env" ]; then
    line=$(grep -E '^[[:space:]]*FM_BACKEND=' "$root/config/backend.env" 2>/dev/null | tail -1 || true)
    line=${line#*=}
    line=${line%\"}
    line=${line#\"}
    line=${line%\'}
    line=${line#\'}
    line=$(printf '%s' "$line" | tr -d '[:space:]')
    [ -n "$line" ] && { echo "$line"; return 0; }
  fi
  echo tmux
}

fm_meta_get() {
  local key=$1 file=$2
  grep "^$key=" "$file" 2>/dev/null | tail -1 | cut -d= -f2-
}

fm_backend_json_get() {
  local expr=$1
  node -e '
const fs = require("fs");
const input = fs.readFileSync(0, "utf8");
const data = input.trim() ? JSON.parse(input) : {};
const expr = process.argv[1].split(".");
let cur = data;
for (const part of expr) {
  if (cur == null) break;
  cur = cur[part];
}
if (cur != null) process.stdout.write(String(cur));
' "$expr"
}

fm_backend_first_terminal() {
  node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(0, "utf8"));
const terms = data.result && data.result.terminals || [];
if (terms[0] && terms[0].handle) process.stdout.write(terms[0].handle);
'
}

fm_backend_parse_worktree_create() {
  # shellcheck disable=SC2016 # Node reads this script literally; shell expansion is not wanted.
  node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(0, "utf8"));
let found = { id: "", path: "", terminal: "" };
function walk(v) {
  if (!v || typeof v !== "object") return;
  if (!found.id && typeof v.worktreeId === "string") found.id = v.worktreeId;
  if (!found.id && typeof v.id === "string" && v.id.includes("::")) found.id = v.id;
  if (!found.path && typeof v.path === "string" && v.path.startsWith("/")) found.path = v.path;
  if (!found.terminal && typeof v.handle === "string" && v.handle.startsWith("term_")) found.terminal = v.handle;
  for (const value of Object.values(v)) walk(value);
}
walk(data.result || data);
process.stdout.write(`${found.id}\t${found.path}\t${found.terminal}`);
'
}

fm_backend_codex_config_path() {
  if [ -n "${FM_ORCA_CODEX_CONFIG:-}" ]; then
    echo "$FM_ORCA_CODEX_CONFIG"
    return 0
  fi
  echo "$HOME/Library/Application Support/orca/codex-runtime-home/home/config.toml"
}

fm_backend_trust_codex_project() {
  local project_path=$1 config_path
  config_path=$(fm_backend_codex_config_path)
  mkdir -p "$(dirname "$config_path")"
  PROJECT_PATH="$project_path" CONFIG_PATH="$config_path" node <<'NODE'
const fs = require("fs");

const configPath = process.env.CONFIG_PATH;
const projectPath = process.env.PROJECT_PATH;
const key = projectPath.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
const header = `[projects."${key}"]`;

let content = "";
try {
  content = fs.readFileSync(configPath, "utf8");
} catch (error) {
  if (error.code !== "ENOENT") throw error;
}

if (!content.includes(header)) {
  const prefix = content.length && !content.endsWith("\n") ? "\n" : "";
  fs.appendFileSync(configPath, `${prefix}\n${header}\ntrust_level = "trusted"\n`);
}
NODE
}

fm_backend_meta_for_selector() {
  local selector=$1 root=${FM_ROOT:-$(fm_backend_root)} state meta base win thread_id opencode_session_id
  state="$root/state"
  base=${selector#fm-}
  if [ -f "$state/$base.meta" ]; then
    echo "$state/$base.meta"
    return 0
  fi
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    win=$(fm_meta_get window "$meta")
    thread_id=$(fm_meta_get thread_id "$meta")
    opencode_session_id=$(fm_meta_get opencode_session_id "$meta")
    case "$selector" in
      "$win"|fm-"$(basename "$meta" .meta)") echo "$meta"; return 0 ;;
      "$thread_id") echo "$meta"; return 0 ;;
      "$opencode_session_id") echo "$meta"; return 0 ;;
      *) case "$win" in *:"$selector"|"$selector") echo "$meta"; return 0 ;; esac ;;
    esac
  done
  return 1
}

fm_backend_tmux_resolve() {
  case "$1" in
    *:*) echo "$1" ;;
    *) tmux list-windows -a -F '#{session_name}:#{window_name}' | grep -m1 ":$1\$" \
       || { echo "error: no window named $1" >&2; return 1; } ;;
  esac
}

fm_backend_capture() {
  local meta=$1 lines=${2:-40} backend target terminal thread_id server_url opencode_session_id
  backend=$(fm_meta_get backend "$meta")
  [ -n "$backend" ] || backend=tmux
  case "$backend" in
    tmux)
      target=$(fm_meta_get window "$meta")
      tmux capture-pane -p -t "$target" -S -"$lines"
      ;;
    orca)
      terminal=$(fm_meta_get terminal "$meta")
      [ -n "$terminal" ] || { echo "error: no terminal= in $meta" >&2; return 1; }
      orca terminal read --terminal "$terminal" --limit "$lines" --json \
        | node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(0, "utf8"));
const r = data.result || {};
if (r.terminal && Array.isArray(r.terminal.tail)) {
  process.stdout.write(r.terminal.tail.join("\n"));
} else {
  process.stdout.write(r.text || r.output || r.content || r.preview || "");
}
'
      ;;
    codex-app)
      thread_id=$(fm_meta_get thread_id "$meta")
      [ -n "$thread_id" ] || { echo "error: no thread_id= in $meta" >&2; return 1; }
      "${FM_ROOT:-$(fm_backend_root)}/bin/fm-codex-app" capture "$thread_id" "$lines"
      ;;
    opencode-server)
      server_url=$(fm_meta_get opencode_server_url "$meta")
      opencode_session_id=$(fm_meta_get opencode_session_id "$meta")
      [ -n "$server_url" ] || { echo "error: no opencode_server_url= in $meta" >&2; return 1; }
      [ -n "$opencode_session_id" ] || { echo "error: no opencode_session_id= in $meta" >&2; return 1; }
      "${FM_ROOT:-$(fm_backend_root)}/bin/fm-opencode-server" capture "$server_url" "$opencode_session_id" "$lines"
      ;;
    *) echo "error: unknown backend '$backend'" >&2; return 1 ;;
  esac
}

fm_backend_orca_terminal_text() {
  local terminal=$1 lines=${2:-40}
  orca terminal read --terminal "$terminal" --limit "$lines" --json \
    | node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(0, "utf8"));
const r = data.result || {};
if (r.terminal && Array.isArray(r.terminal.tail)) {
  process.stdout.write(r.terminal.tail.join("\n"));
} else {
  process.stdout.write(r.text || r.output || r.content || r.preview || "");
}
'
}

fm_backend_send_text() {
  local meta=$1 text=$2 backend target terminal thread_id root server_url opencode_session_id
  backend=$(fm_meta_get backend "$meta")
  [ -n "$backend" ] || backend=tmux
  case "$backend" in
    tmux)
      target=$(fm_meta_get window "$meta")
      tmux send-keys -t "$target" -l "$text"
      case "$text" in /*) sleep 1.2 ;; *) sleep 0.3 ;; esac
      tmux send-keys -t "$target" Enter
      ;;
    orca)
      terminal=$(fm_meta_get terminal "$meta")
      [ -n "$terminal" ] || { echo "error: no terminal= in $meta" >&2; return 1; }
      orca terminal send --terminal "$terminal" --text "$text" --enter --json >/dev/null
      ;;
    codex-app)
      root=${FM_ROOT:-$(fm_backend_root)}
      thread_id=$(fm_meta_get thread_id "$meta")
      [ -n "$thread_id" ] || { echo "error: no thread_id= in $meta" >&2; return 1; }
      "$root/bin/fm-codex-app" send "$thread_id" "$text"
      ;;
    opencode-server)
      root=${FM_ROOT:-$(fm_backend_root)}
      server_url=$(fm_meta_get opencode_server_url "$meta")
      opencode_session_id=$(fm_meta_get opencode_session_id "$meta")
      [ -n "$server_url" ] || { echo "error: no opencode_server_url= in $meta" >&2; return 1; }
      [ -n "$opencode_session_id" ] || { echo "error: no opencode_session_id= in $meta" >&2; return 1; }
      "$root/bin/fm-opencode-server" send "$server_url" "$opencode_session_id" "$text" >/dev/null
      ;;
    *) echo "error: unknown backend '$backend'" >&2; return 1 ;;
  esac
}

fm_backend_send_key() {
  local meta=$1 key=$2 backend target terminal thread_id server_url opencode_session_id root
  backend=$(fm_meta_get backend "$meta")
  [ -n "$backend" ] || backend=tmux
  case "$backend" in
    tmux)
      target=$(fm_meta_get window "$meta")
      tmux send-keys -t "$target" "$key"
      ;;
    orca)
      terminal=$(fm_meta_get terminal "$meta")
      [ -n "$terminal" ] || { echo "error: no terminal= in $meta" >&2; return 1; }
      case "$key" in
        Escape|C-c) orca terminal send --terminal "$terminal" --interrupt --json >/dev/null ;;
        Enter) orca terminal send --terminal "$terminal" --text "" --enter --json >/dev/null ;;
        *) echo "error: unsupported Orca key '$key'" >&2; return 1 ;;
      esac
      ;;
    codex-app)
      thread_id=$(fm_meta_get thread_id "$meta")
      [ -n "$thread_id" ] || { echo "error: no thread_id= in $meta" >&2; return 1; }
      case "$key" in
        Escape|C-c) "${FM_ROOT:-$(fm_backend_root)}/bin/fm-codex-app" interrupt "$thread_id" >/dev/null ;;
        Enter) "${FM_ROOT:-$(fm_backend_root)}/bin/fm-codex-app" send "$thread_id" "" ;;
        *) echo "error: unsupported Codex App key '$key'" >&2; return 1 ;;
      esac
      ;;
    opencode-server)
      root=${FM_ROOT:-$(fm_backend_root)}
      server_url=$(fm_meta_get opencode_server_url "$meta")
      opencode_session_id=$(fm_meta_get opencode_session_id "$meta")
      [ -n "$server_url" ] || { echo "error: no opencode_server_url= in $meta" >&2; return 1; }
      [ -n "$opencode_session_id" ] || { echo "error: no opencode_session_id= in $meta" >&2; return 1; }
      case "$key" in
        Escape|C-c) "$root/bin/fm-opencode-server" interrupt "$server_url" "$opencode_session_id" >/dev/null ;;
        Enter) "$root/bin/fm-opencode-server" send "$server_url" "$opencode_session_id" "" >/dev/null ;;
        *) echo "error: unsupported OpenCode server key '$key'" >&2; return 1 ;;
      esac
      ;;
    *) echo "error: unknown backend '$backend'" >&2; return 1 ;;
  esac
}

fm_backend_status() {
  local meta=$1 backend target terminal thread_id server_url opencode_session_id root
  backend=$(fm_meta_get backend "$meta")
  [ -n "$backend" ] || backend=tmux
  case "$backend" in
    tmux)
      target=$(fm_meta_get window "$meta")
      if tmux display-message -p -t "$target" '#{pane_pid}' >/dev/null 2>&1; then echo status=present; else echo status=missing; fi
      ;;
    orca)
      terminal=$(fm_meta_get terminal "$meta")
      [ -n "$terminal" ] || { echo "error: no terminal= in $meta" >&2; return 1; }
      if orca terminal read --terminal "$terminal" --limit 1 --json >/dev/null 2>&1; then echo status=present; else echo status=missing; fi
      ;;
    codex-app)
      root=${FM_ROOT:-$(fm_backend_root)}
      thread_id=$(fm_meta_get thread_id "$meta")
      [ -n "$thread_id" ] || { echo "error: no thread_id= in $meta" >&2; return 1; }
      "$root/bin/fm-codex-app" status "$thread_id"
      ;;
    opencode-server)
      root=${FM_ROOT:-$(fm_backend_root)}
      server_url=$(fm_meta_get opencode_server_url "$meta")
      opencode_session_id=$(fm_meta_get opencode_session_id "$meta")
      [ -n "$server_url" ] || { echo "error: no opencode_server_url= in $meta" >&2; return 1; }
      [ -n "$opencode_session_id" ] || { echo "error: no opencode_session_id= in $meta" >&2; return 1; }
      "$root/bin/fm-opencode-server" status "$server_url" "$opencode_session_id"
      ;;
    *) echo "error: unknown backend '$backend'" >&2; return 1 ;;
  esac
}
