#!/usr/bin/env bash
# Bootstrap detection, best-effort fleet refresh/prune, and installs.
# Usage: fm-bootstrap.sh
#          Detect: prints one line per problem and exits 0. Silent = all good.
#          Lines: "MISSING: <tool> (install: <command>)", "NEEDS_GH_AUTH",
#                 "CREW_HARNESS_OVERRIDE: <name>", "FLEET_SYNC: <repo>: skipped: <reason>".
#          treehouse is also MISSING when its installed version lacks
#          "treehouse get --lease" support or post_create hook support.
#          treehouse-post-create-hook is MISSING when Treehouse is not wired
#          to firstmate's global post_create hook.
#          Fleet sync fetches, fast-forwards, and prunes gone local branches;
#          it is bounded by FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT, default 20s.
#          Set FM_FLEET_PRUNE=0 to skip branch pruning during that refresh.
#        fm-bootstrap.sh install <tool>...
#          Install the named tools (only ones the captain approved).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

fleet_sync() {
  [ -x "$FM_ROOT/bin/fm-fleet-sync.sh" ] || return 0
  [ -d "$PROJECTS" ] || return 0

  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-fleet-sync.XXXXXX" 2>/dev/null) || return 0
  monitor_was_on=0
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m 2>/dev/null || true
  "$FM_ROOT/bin/fm-fleet-sync.sh" >"$tmp" 2>/dev/null &
  pid=$!

  timeout=${FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT:-20}
  case "$timeout" in ''|*[!0-9]*) timeout=20 ;; esac
  start=$SECONDS
  while jobs -r -p | grep -qx "$pid"; do
    if [ $((SECONDS - start)) -ge "$timeout" ]; then
      kill -TERM "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
      echo "FLEET_SYNC: fleet: skipped: bootstrap refresh timed out"
      rm -f "$tmp"
      return 0
    fi
    sleep 1
  done
  wait "$pid" 2>/dev/null || true
  [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true

  while IFS= read -r line; do
    case "$line" in
      *': skipped: local-only project') ;;
      *': skipped: no origin remote') ;;
      *': skipped:'*) echo "FLEET_SYNC: $line" ;;
    esac
  done < "$tmp"
  rm -f "$tmp"
}

install_cmd() {
  case "$1" in
    tmux|node|gh) echo "brew install $1  # or the platform's package manager" ;;
    treehouse) echo "curl -fsSL https://kunchenguid.github.io/treehouse/install.sh | sh" ;;
    treehouse-post-create-hook) printf '%q install treehouse-post-create-hook\n' "$FM_ROOT/bin/fm-bootstrap.sh" ;;
    no-mistakes) echo "curl -fsSL https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh | sh" ;;
    gh-axi|chrome-devtools-axi|lavish-axi) echo "npm install -g $1 && $1 setup hooks" ;;
    *) return 1 ;;
  esac
}

TOOLS="tmux node gh treehouse no-mistakes gh-axi chrome-devtools-axi lavish-axi"

treehouse_supports_lease() {
  treehouse get --help 2>&1 | grep -Eq '(^|[^[:alnum:]_-])--lease([^[:alnum:]_-]|$)'
}

treehouse_supports_post_create() {
  version=$(treehouse --version 2>/dev/null) || return 1
  version=${version#treehouse }
  version=${version#v}
  case "$version" in
    [0-9]*.[0-9]*.[0-9]*)
      major=${version%%.*}
      rest=${version#*.}
      minor=${rest%%.*}
      patch=${rest#*.}
      patch=${patch%%[!0-9]*}
      [ -n "$patch" ] || patch=0
      [ "$major" -gt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -gt 8 ]; } || { [ "$major" -eq 1 ] && [ "$minor" -eq 8 ] && [ "$patch" -ge 0 ]; }
      ;;
    *) return 1 ;;
  esac
}

treehouse_config_path() {
  printf '%s\n' "${TREEHOUSE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/treehouse/config.toml}"
}

treehouse_hook_path() {
  cd "$FM_ROOT/bin" 2>/dev/null && printf '%s/fm-treehouse-post-create.sh\n' "$(pwd -P)"
}

treehouse_hook_command_usable() {
  command=$1
  case "$command" in
    *fm-treehouse-post-create.sh*) ;;
    *) return 1 ;;
  esac
  hook_path=$(printf '%s\n' "$command" | awk '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function emit_word() {
      word = trim(word)
      if (word ~ /^\/.*\/fm-treehouse-post-create\.sh$/) {
        print word
        exit
      }
      word = ""
    }
    {
      line = trim($0)
      if (line ~ /^\/.*\/fm-treehouse-post-create\.sh$/) {
        print line
        exit
      }
      quote = ""
      word = ""
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (quote == "" && c ~ /[[:space:]]/) {
          emit_word()
          continue
        }
        if (c == "\\" && i < length(line)) {
          word = word substr(line, i + 1, 1)
          i++
          continue
        }
        if (c == "\"" || c == "'\''") {
          if (quote == "") {
            quote = c
            continue
          }
          if (quote == c) {
            quote = ""
            continue
          }
        }
        word = word c
      }
      emit_word()
    }
  ')
  [ -n "$hook_path" ] || return 1
  case "$hook_path" in
    /*) ;;
    *) return 1 ;;
  esac
  [ -x "$hook_path" ]
}

treehouse_post_create_hook_configured() {
  config=$(treehouse_config_path)
  [ -f "$config" ] || return 1
  while IFS= read -r command; do
    treehouse_hook_command_usable "$command" && return 0
  done < <(awk '
    function strip_comment(line,    i, c, prev, quote, out) {
      quote = ""
      out = ""
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        prev = i > 1 ? substr(line, i - 1, 1) : ""
        if (quote == "" && c == "#") {
          break
        }
        out = out c
        if ((c == "\"" || c == "'\''") && prev != "\\") {
          if (quote == "") {
            quote = c
          } else if (quote == c) {
            quote = ""
          }
        }
      }
      return out
    }
    function emit_strings(line,    i, c, prev, quote, value) {
      quote = ""
      value = ""
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        prev = i > 1 ? substr(line, i - 1, 1) : ""
        if ((c == "\"" || c == "'\''") && prev != "\\") {
          if (quote == "") {
            quote = c
            value = ""
            continue
          }
          if (quote == c) {
            print value
            quote = ""
            value = ""
            continue
          }
        }
        if (quote != "") {
          value = value c
        }
      }
    }
    {
      clean = strip_comment($0)
      if (clean ~ /^[[:space:]]*\[[^]]+\][[:space:]]*$/) {
        in_hooks = (clean ~ /^[[:space:]]*\[hooks\][[:space:]]*$/)
        in_post_create = 0
      }
      post_create_line = 0
      if (in_hooks && clean ~ /^[[:space:]]*post_create[[:space:]]*=/) {
        in_post_create = 1
        post_create_line = 1
      }
      if (in_hooks && in_post_create) {
        emit_strings(clean)
      }
      if (in_hooks && in_post_create && (clean ~ /\]/ || (post_create_line && clean !~ /\[/))) {
        in_post_create = 0
      }
    }
  ' "$config")
  return 1
}

treehouse_config_has_hooks_section() {
  awk '
    function strip_comment(line,    i, c, prev, quote, out) {
      quote = ""
      out = ""
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        prev = i > 1 ? substr(line, i - 1, 1) : ""
        if (quote == "" && c == "#") {
          break
        }
        out = out c
        if ((c == "\"" || c == "'\''") && prev != "\\") {
          if (quote == "") {
            quote = c
          } else if (quote == c) {
            quote = ""
          }
        }
      }
      return out
    }
    { clean = strip_comment($0) }
    clean ~ /^[[:space:]]*\[hooks\][[:space:]]*$/ { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$1"
}

treehouse_config_has_post_create() {
  awk '
    function strip_comment(line,    i, c, prev, quote, out) {
      quote = ""
      out = ""
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        prev = i > 1 ? substr(line, i - 1, 1) : ""
        if (quote == "" && c == "#") {
          break
        }
        out = out c
        if ((c == "\"" || c == "'\''") && prev != "\\") {
          if (quote == "") {
            quote = c
          } else if (quote == c) {
            quote = ""
          }
        }
      }
      return out
    }
    {
      clean = strip_comment($0)
      if (clean ~ /^[[:space:]]*\[[^]]+\][[:space:]]*$/) {
        in_hooks = (clean ~ /^[[:space:]]*\[hooks\][[:space:]]*$/)
      }
      if (in_hooks && clean ~ /^[[:space:]]*post_create[[:space:]]*=/) {
        found = 1
      }
    }
    END { exit found ? 0 : 1 }
  ' "$1"
}

append_treehouse_post_create_hook() {
  config=$1
  hook=$2
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-treehouse-config.XXXXXX") || return 1
  if awk -v hook="$hook" '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function strip_comment(line,    i, c, prev, quote, out) {
      quote = ""
      out = ""
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        prev = i > 1 ? substr(line, i - 1, 1) : ""
        if (quote == "" && c == "#") {
          break
        }
        out = out c
        if ((c == "\"" || c == "'\''") && prev != "\\") {
          if (quote == "") {
            quote = c
          } else if (quote == c) {
            quote = ""
          }
        }
      }
      return out
    }
    function append_to_single_line(line, hook,    open, rel_close, close_pos, inside, prefix, suffix) {
      open = index(line, "[")
      rel_close = index(substr(line, open + 1), "]")
      if (!open || !rel_close) {
        return line
      }
      close_pos = open + rel_close
      inside = trim(substr(line, open + 1, close_pos - open - 1))
      prefix = substr(line, 1, close_pos - 1)
      suffix = substr(line, close_pos)
      if (inside == "") {
        return prefix "\"" hook "\"" suffix
      }
      return prefix ", \"" hook "\"" suffix
    }
    function add_comma_before_comment(line,    hash, body, comment) {
      hash = index(line, "#")
      if (hash) {
        body = substr(line, 1, hash - 1)
        comment = substr(line, hash)
      } else {
        body = line
        comment = ""
      }
      if (body ~ /,[[:space:]]*$/) {
        return line
      }
      sub(/[[:space:]]*$/, "", body)
      return body "," (comment == "" ? "" : " " comment)
    }
    {
      lines[NR] = $0
      clean = strip_comment($0)
      if (clean ~ /^[[:space:]]*\[[^]]+\][[:space:]]*$/) {
        in_hooks = (clean ~ /^[[:space:]]*\[hooks\][[:space:]]*$/)
        if (in_post_create && !pc_end) {
          pc_end = NR - 1
        }
        in_post_create = 0
      }
      if (in_hooks && clean ~ /^[[:space:]]*post_create[[:space:]]*=/) {
        pc_start = NR
        in_post_create = 1
      }
      if (in_post_create && clean ~ /\]/) {
        pc_end = NR
        in_post_create = 0
      }
    }
    END {
      if (!pc_start || !pc_end) {
        exit 1
      }
      if (pc_start == pc_end) {
        lines[pc_start] = append_to_single_line(lines[pc_start], hook)
      } else {
        last_value = 0
        for (i = pc_start + 1; i < pc_end; i++) {
          candidate = lines[i]
          sub(/[[:space:]]*#.*/, "", candidate)
          if (trim(candidate) != "") {
            last_value = i
          }
        }
        if (last_value) {
          lines[last_value] = add_comma_before_comment(lines[last_value])
        }
      }
      for (i = 1; i <= NR; i++) {
        if (i == pc_end && pc_start != pc_end) {
          indent = lines[pc_end]
          sub(/[^[:space:]].*$/, "", indent)
          printf "%s\"%s\"\n", indent "  ", hook
        }
        print lines[i]
      }
    }
  ' "$config" >"$tmp" && mv "$tmp" "$config"; then
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

install_treehouse_hook() {
  config=$(treehouse_config_path)
  hook=$(treehouse_hook_path) || return 1
  if treehouse_post_create_hook_configured; then
    return 0
  fi
  mkdir -p "$(dirname "$config")"
  if [ ! -f "$config" ]; then
    printf '[hooks]\npost_create = ["%s"]\n' "$hook" >"$config"
    return 0
  fi
  if ! treehouse_config_has_hooks_section "$config"; then
    printf '\n[hooks]\npost_create = ["%s"]\n' "$hook" >>"$config"
    return 0
  fi
  if ! treehouse_config_has_post_create "$config"; then
    tmp=$(mktemp "${TMPDIR:-/tmp}/fm-treehouse-config.XXXXXX") || return 1
    if awk -v hook="$hook" '
      function strip_comment(line,    i, c, prev, quote, out) {
        quote = ""
        out = ""
        for (i = 1; i <= length(line); i++) {
          c = substr(line, i, 1)
          prev = i > 1 ? substr(line, i - 1, 1) : ""
          if (quote == "" && c == "#") {
            break
          }
          out = out c
          if ((c == "\"" || c == "'\''") && prev != "\\") {
            if (quote == "") {
              quote = c
            } else if (quote == c) {
              quote = ""
            }
          }
        }
        return out
      }
      { print }
      !inserted && strip_comment($0) ~ /^[[:space:]]*\[hooks\][[:space:]]*$/ {
        printf "post_create = [\"%s\"]\n", hook
        inserted = 1
      }
    ' "$config" >"$tmp" && mv "$tmp" "$config"; then
      rm -f "$tmp"
      return 0
    fi
    rm -f "$tmp"
    return 1
  fi
  append_treehouse_post_create_hook "$config" "$hook"
}

if [ "${1:-}" = "install" ]; then
  shift
  [ $# -gt 0 ] || { echo "usage: fm-bootstrap.sh install <tool>..." >&2; exit 1; }
  for t in "$@"; do
    cmd=$(install_cmd "$t") || { echo "error: unknown tool $t" >&2; exit 1; }
    if [ "$t" = treehouse-post-create-hook ]; then
      echo "installing $t: $cmd"
      install_treehouse_hook || exit 1
      continue
    fi
    cmd=${cmd%%  #*}
    echo "installing $t: $cmd"
    eval "$cmd"
  done
  exit 0
fi

for t in $TOOLS; do
  command -v "$t" >/dev/null || echo "MISSING: $t (install: $(install_cmd "$t"))"
done
if command -v treehouse >/dev/null 2>&1 && { ! treehouse_supports_lease || ! treehouse_supports_post_create; }; then
  echo "MISSING: treehouse (install: $(install_cmd treehouse))"
fi
if command -v treehouse >/dev/null 2>&1 && treehouse_supports_lease && treehouse_supports_post_create && ! treehouse_post_create_hook_configured; then
  echo "MISSING: treehouse-post-create-hook (install: $(install_cmd treehouse-post-create-hook))"
fi
gh auth status >/dev/null 2>&1 || echo "NEEDS_GH_AUTH"
crew=
[ -f "$CONFIG/crew-harness" ] && crew=$(tr -d '[:space:]' < "$CONFIG/crew-harness" || true)
[ -n "$crew" ] && [ "$crew" != "default" ] && echo "CREW_HARNESS_OVERRIDE: $crew"
fleet_sync
exit 0
