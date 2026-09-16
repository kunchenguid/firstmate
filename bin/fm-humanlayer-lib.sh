#!/usr/bin/env bash

fm_humanlayer_require_backend() {
  case "$1" in
    tmux|herdr) return 0 ;;
    *) printf "error: unsupported backend for HumanLayer dispatch: %s (supported: tmux, herdr)\n" "$1" >&2; return 1 ;;
  esac
}

# Plain transcript-shaped input cannot prove completion. Only the styled
# vendor completion row can retire an earlier prompt; a literal > inside a
# multiline draft must not establish an empty composer.
# The styled [Done] row renders in two verified vendor dialects and the fold
# must accept both (each was captured live from a real settled turn):
#   tmux `-e`:   ESC[38;2;34;197;94m[Done]ESC[39m complete
#   herdr ansi:  ESC[0mESC[38;2;34;197;94m[Done]ESC[0m complete (rows also
#                carry CR line endings and per-run attribute resets)
# So the completion match tolerates leading SGR runs before the color code
# and both ESC[39m and ESC[0m as the reset after the [Done] token.
fm_humanlayer_screen_state() {
  awk '
    BEGIN { esc = sprintf("%c", 27) }
    {
      # herdr ANSI captures terminate every line with CR (verified live).
      # Whether CR counts as [[:space:]] varies by awk implementation and
      # locale, so strip it explicitly instead of relying on the class.
      sub(/\r$/, "")
      completed = $0 ~ ("^(" esc "\\[[0-9;]*m)*" esc "\\[38;2;(34;197;94|239;68;68|234;179;8)m\\[Done\\]" esc "\\[(0|m|39)m")
      gsub(esc "\\[[0-9;]*m", "")
      if (NR == 1 && $0 ~ /^\[codex-provider\] using sse transport([[:space:]].*)?$/) startup = 1
      if (NR == 2 && startup == 1 && $0 ~ /^codelayer - provider: [^,[:space:]]+, model: [^[:space:]]+[[:space:]]*$/) startup = 2
      if (NR > 2 && startup == 2 && $0 ~ /[^[:space:]]/) {
        if ($0 ~ /^>[[:space:]]*$/) pending = 0
        startup = 0
      }
      if (completed) { pending = 0; composer = 0; settled = 1 }
      else if ($0 ~ /^>/) {
        if (composer) pending = 1
        composer = 1
        if ($0 !~ /^>[[:space:]]*$/) pending = 1
      } else if ((!settled || composer) && $0 ~ /[^[:space:]]/) pending = 1
      if ($0 ~ /[^[:space:]]/) last = $0
    }
    END { print !pending && last ~ /^>[[:space:]]*$/ ? "idle" : "unknown" }
  '
}

# Prefer styling where the backend exposes it. Plain captures deliberately
# cannot clear ambiguous prompt history using a pasted completion marker.
fm_humanlayer_capture() {  # <backend> <target> [expected-label]
  fm_humanlayer_require_backend "$1" || return 1
  if command -v fm_backend_source >/dev/null 2>&1; then
    fm_backend_source "$1" || return 1
  fi
  case "$1" in
    tmux) tmux capture-pane -e -p -J -t "$2" -S - 2>/dev/null ;;
    herdr)
      out=$(fm_backend_herdr_capture_ansi "$2" 200 "${3:-}" 2>/dev/null) || return 1
      # herdr's ANSI stream terminates every line with CR (verified live);
      # strip it here so every consumer of this capture - including awk
      # folds whose [[:space:]] handling of CR varies by implementation -
      # sees LF rows.
      printf '%s' "$out" | tr -d '\r'
      ;;
  esac
}

# HumanLayer readline redraws the composer with erase-to-end-of-screen and
# inserts one padding space before column-one moves at soft wraps. Preserve
# the final redraw and its exact text before stripping the remaining ANSI;
# stripping first concatenates erased drafts and retains the wrap padding.
# This normalizes raw pipe output only, never an already-rendered capture.
fm_humanlayer_pipe_text() {
  awk '
    BEGIN { esc = sprintf("%c", 27) }
    {
      sub("^.*" esc "\\[0J", "")
      gsub(" " esc "\\[1G", "")
      print
    }
  ' | fm_composer_strip_ansi | tr -d '\r'
}

# A pipe attached at a verified empty composer starts after its existing >
# prefix. Only that stream may match an unprefixed first row.
fm_humanlayer_submission_seen() {
  FM_HL_SUBMIT_TEXT="$1" FM_HL_EMPTY_COMPOSER="${2:-}" awk '
    BEGIN { count = split(ENVIRON["FM_HL_SUBMIT_TEXT"], text, "\n") }
    {
      # herdr ANSI captures terminate lines with CR; strip explicitly rather
      # than relying on implementation-specific [[:space:]] handling.
      sub(/\r$/, "")
    }
    submitted && remaining > 0 {
      if ($0 != text[count - remaining + 1]) submitted = 0
      remaining--
      next
    }
    $0 == "> " text[1] || (NR == 1 && ENVIRON["FM_HL_EMPTY_COMPOSER"] == "1" && $0 == text[1]) { submitted = 1; remaining = count - 1; confirmed = 0; next }
    confirmed { next }
    /^>[[:space:]]*$/ { next }
    /^>/ { submitted = ($0 == "> " text[1]); remaining = count - 1; confirmed = 0; next }
    submitted && /^\[(Tool|Assistant|Done)\]/ { confirmed = 1 }
    END { exit !confirmed }
  '
}

fm_humanlayer_processes_active() {
  FM_HL_FOREGROUND_PIDS="$1" awk '
    BEGIN {
      count = split(ENVIRON["FM_HL_FOREGROUND_PIDS"], ids, /[[:space:]]+/)
      for (i = 1; i <= count; i++) foreground[ids[i]] = 1
    }
    NF >= 5 {
      parent[$1] = $2; status[$1] = $4
      name[$1] = $5; sub(/^.*\//, "", name[$1])
      if (foreground[$1] && name[$1] == "humanlayer" && $4 !~ /[ZTX]/) root[$1] = 1
    }
    END {
      for (pid in parent) {
        if (status[pid] ~ /[ZTX]/ || name[pid] ~ /^(humanlayer|node|codex)$/) continue
        ancestor = parent[pid]
        for (depth = 0; depth < 128 && ancestor > 1; depth++) {
          if (root[ancestor]) exit 0
          ancestor = parent[ancestor]
        }
      }
      exit 1
    }
  '
}


fm_humanlayer_backend_submit() {
  local backend=$1 baseline=$2 target=$3 text=$4 retries=$5 interval=$6 settle=$7 label=${8:-}
  local screen prefix overlap i=0
  . "$FM_BACKEND_LIB_DIR/fm-composer-lib.sh"
  prefix=$(printf '%s' "$baseline" | fm_composer_strip_ansi | tr -d '\r')
  prefix=${prefix%>*}
  "fm_backend_${backend}_send_literal" "$target" "$text" "$label" || { printf 'send-failed'; return 0; }
  sleep "$settle"
  fm_backend_send_key "$backend" "$target" Enter "$label" || { printf 'send-failed'; return 0; }
  retries=${FM_HUMANLAYER_CONFIRM_POLLS:-$retries}
  interval=${FM_HUMANLAYER_CONFIRM_INTERVAL:-$interval}
  while [ "$i" -lt "$retries" ]; do
    sleep "$interval"
    if screen=$(fm_humanlayer_capture "$backend" "$target" "$label"); then
      screen=$(printf '%s' "$screen" | fm_composer_strip_ansi | tr -d '\r')
      overlap=$prefix
      while :; do
        case "$screen" in
          "$overlap"*)
            if printf '%s' "${screen#"$overlap"}" | fm_humanlayer_submission_seen "$text"; then
              printf 'empty'
              return 0
            fi
            break
            ;;
        esac
        case "$overlap" in
          *$'\n'*) overlap=${overlap#*$'\n'} ;;
          *) break ;;
        esac
        [ -n "$overlap" ] || break
      done
    fi
    i=$((i + 1))
  done
  printf 'unknown'
}
