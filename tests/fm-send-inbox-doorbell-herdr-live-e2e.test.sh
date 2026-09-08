#!/usr/bin/env bash
# Self-contained cross-version Herdr doorbell guard (live-harness-optin family).
#
# Run with FM_SEND_INBOX_HERDR_LIVE_E2E=1. Each version gets a short, private
# XDG universe and a non-default named session. Herdr 0.8.2 may use the already
# installed exact-version binary; otherwise the pinned official asset is
# downloaded. Herdr 0.9.0 is downloaded into its scratch prefix. Downloads are
# size-bounded and SHA-256 verified. No system binary or default session is
# changed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_SEND_INBOX_HERDR_LIVE_E2E curl jq claude

unset NO_MISTAKES_GATE
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION

TIMEOUT=${FM_SEND_INBOX_HERDR_LIVE_TIMEOUT:-180}
CHECKED=0
UNAVAILABLE=0
ASSET=
SHA256=

release_asset() { # <version>
  local version=$1
  case "$(uname -s)-$(uname -m)-$version" in
    Darwin-arm64-0.8.2) ASSET=herdr-macos-aarch64; SHA256=a5d4f4d504d8b309c91f811050559300faba31258425f53c50852fc96f6ae574 ;;
    Darwin-x86_64-0.8.2) ASSET=herdr-macos-x86_64; SHA256=ab50262c8190cd7aa9056d249d255c08c328c3e8716de9cfa29db4f131b8e2c1 ;;
    Linux-aarch64-0.8.2|Linux-arm64-0.8.2) ASSET=herdr-linux-aarch64; SHA256=f55610658e1c2e0d2aaef730b4b2ab885f7f8ba00285ab372bfb14f2e3d5b40d ;;
    Linux-x86_64-0.8.2) ASSET=herdr-linux-x86_64; SHA256=976150a14d490c94b243ea2e1a7eb2dfb67f12e36b182db90936f6728e6aecf4 ;;
    Darwin-arm64-0.9.0) ASSET=herdr-macos-aarch64; SHA256=32b53df09872628059c789a69f02a6b8e29e14ddf26711421f3463f70c1aef17 ;;
    Darwin-x86_64-0.9.0) ASSET=herdr-macos-x86_64; SHA256=d0c920b2a126a74809fa1491411c9a097a44786cac9c2ca51b818a995581cf16 ;;
    Linux-aarch64-0.9.0|Linux-arm64-0.9.0) ASSET=herdr-linux-aarch64; SHA256=9c8db20fb7e7427b138d5367113f1621ffd319f2f65d6f009e2594029115f0d2 ;;
    Linux-x86_64-0.9.0) ASSET=herdr-linux-x86_64; SHA256=4fa1a01158dd8043da92d31b270780b0dcc10603038d9b61cac4d81ab63fb71f ;;
    *) return 1 ;;
  esac
}

file_sha256() { # <path>
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    return 1
  fi
}

obtain_version() { # <version> <prefix>
  local version=$1 prefix=$2 installed actual url
  mkdir -p "$prefix/bin"
  installed=$(command -v herdr 2>/dev/null || true)
  if [ "$version" = 0.8.2 ] && [ -n "$installed" ] && [ "$("$installed" --version 2>/dev/null | awk '{print $2; exit}')" = "$version" ]; then
    cp "$installed" "$prefix/bin/herdr" || return 1
    chmod 0755 "$prefix/bin/herdr"
    return 0
  fi
  release_asset "$version" || return 1
  url="https://github.com/ogulcancelik/herdr/releases/download/v${version}/${ASSET}"
  if ! curl -fsSL --max-filesize 30000000 "$url" -o "$prefix/bin/herdr.download"; then
    return 1
  fi
  actual=$(file_sha256 "$prefix/bin/herdr.download") || return 1
  [ "$actual" = "$SHA256" ] || {
    printf 'not ok - Herdr %s asset checksum mismatch (expected %s, got %s)\n' "$version" "$SHA256" "$actual" >&2
    return 1
  }
  mv "$prefix/bin/herdr.download" "$prefix/bin/herdr"
  chmod 0755 "$prefix/bin/herdr"
  [ "$("$prefix/bin/herdr" --version 2>/dev/null | awk '{print $2; exit}')" = "$version" ] || return 1
}

composer_content() { # <target>
  local cap caps
  cap=$(fm_backend_capture herdr "$1" "$FM_COMPOSER_CAPTURE_LINES" claude 2>/dev/null) || return 1
  caps=$(printf 'styled=0\ncursor=0\nidentity=0\nrows=%s' "$FM_COMPOSER_CAPTURE_LINES")
  fm_composer_extract_selected_content "$caps" "$cap" 2>/dev/null
}

wait_for_idle_composer() { # <target> <pane>
  local target=$1 pane=$2 i=0 state agent
  while [ "$i" -lt 60 ]; do
    state=$(fm_backend_composer_state herdr "$target" claude 2>/dev/null || true)
    agent=$(herdr agent get "$pane" --session "$HERDR_SESSION" 2>/dev/null | jq -r '.result.agent.agent_status // empty' 2>/dev/null || true)
    case "$agent:$state" in idle:empty|done:empty|blocked:empty) return 0 ;; esac
    sleep 1
    i=$((i + 1))
  done
  return 1
}

run_version() ( # <version> <prefix>
  local version=$1 prefix=$2 session pane ws target home rec handled line acted i rc
  local foreign foreign_before foreign_after safety_rec safety_handled server_pid=
  export XDG_CONFIG_HOME="$prefix/c"
  export XDG_STATE_HOME="$prefix/s"
  export XDG_DATA_HOME="$prefix/d"
  export PATH="$prefix/bin:$PATH"
  export HERDR_SESSION="fm-lab-doorbell-${version//./}-$$"
  session=$HERDR_SESSION
  mkdir -p "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$XDG_DATA_HOME"

  cleanup_version() {
    local cleanup_rc=$?
    trap - EXIT
    herdr server stop --session "$session" >/dev/null 2>&1 || cleanup_rc=1
    [ -z "$server_pid" ] || wait "$server_pid" 2>/dev/null || true
    rm -rf "$prefix"
    exit "$cleanup_rc"
  }
  trap cleanup_version EXIT

  herdr server --session "$session" >"$prefix/server.log" 2>&1 &
  server_pid=$!
  i=0
  while [ "$i" -lt 60 ]; do
    [ "$(herdr status --json --session "$session" 2>/dev/null | jq -r '.server.running // false' 2>/dev/null)" = true ] && break
    sleep 1
    i=$((i + 1))
  done
  [ "$i" -lt 60 ] || fail "Herdr $version: isolated server did not start"

  ws=$(herdr workspace create --cwd "$ROOT" --label "doorbell-$version" --no-focus --session "$session") \
    || fail "Herdr $version: could not create isolated workspace"
  pane=$(printf '%s' "$ws" | jq -er '.result.root_pane.pane_id') \
    || fail "Herdr $version: workspace create returned no pane"
  target="$session:$pane"
  herdr pane run "$pane" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}'" --session "$session" >/dev/null \
    || fail "Herdr $version: could not launch real Claude"
  wait_for_idle_composer "$target" "$pane" || fail "Herdr $version: Claude did not reach an empty idle composer"

  home="$prefix/home"
  mkdir -p "$home/state"
  acted="$prefix/recovery-acted"
  rec=$(FM_STATE_OVERRIDE="$home/state" fm_task_inbox_write "$home/state" "herdr-$version" \
    "Firstmate live check: run exactly this shell command now: touch $acted - then follow the mv instruction you were given for this message. Reply with one short line.") \
    || fail "Herdr $version: could not write recovery record"
  handled="$home/state/herdr-$version.inbox/handled/${rec##*/}"
  line=$(fm_task_inbox_doorbell_line "$rec") || fail "Herdr $version: could not form doorbell"

  herdr pane send-text "$pane" "$line" --session "$session" >/dev/null \
    || fail "Herdr $version: could not stage swallowed doorbell"
  sleep 2
  [ "$(fm_backend_composer_state herdr "$target" claude 2>/dev/null || true)" = pending ] \
    || fail "Herdr $version: staged doorbell was not visibly pending"
  fm_task_inbox_composer_holds_doorbell herdr "$target" "$rec" claude \
    || fail "Herdr $version: pending composer did not hold the exact doorbell"
  fm_task_inbox_ring herdr "$target" "$rec" claude \
    || fail "Herdr $version: fm_task_inbox_ring did not recover the swallowed Enter"

  i=0
  while [ "$i" -lt "$TIMEOUT" ]; do
    [ -f "$handled" ] && [ -e "$acted" ] && break
    sleep 1
    i=$((i + 1))
  done
  [ -f "$handled" ] && [ -e "$acted" ] \
    || fail "Herdr $version: worker did not act and acknowledge recovered doorbell within ${TIMEOUT}s"
  pass "Herdr $version: swallowed doorbell recovered through real fm_task_inbox_ring"

  wait_for_idle_composer "$target" "$pane" || fail "Herdr $version: Claude did not return idle before draft-safety check"
  foreign="Human draft must stay unsent $version $$"
  safety_rec=$(FM_STATE_OVERRIDE="$home/state" fm_task_inbox_write "$home/state" "draft-$version" \
    "touch $prefix/unsafe-acted") || fail "Herdr $version: could not write draft-safety record"
  safety_handled="$home/state/draft-$version.inbox/handled/${safety_rec##*/}"
  herdr pane send-text "$pane" "$foreign" --session "$session" >/dev/null \
    || fail "Herdr $version: could not stage foreign draft"
  sleep 2
  [ "$(fm_backend_composer_state herdr "$target" claude 2>/dev/null || true)" = pending ] \
    || fail "Herdr $version: foreign draft was not visibly pending"
  foreign_before=$(composer_content "$target") || fail "Herdr $version: could not read staged foreign draft"
  [ "$foreign_before" = "$foreign" ] || fail "Herdr $version: staged foreign draft content was not exact"

  fm_task_inbox_ring herdr "$target" "$safety_rec" claude >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 1 ] || fail "Herdr $version: ring did not defer on foreign draft (status $rc)"
  sleep 2
  foreign_after=$(composer_content "$target") || fail "Herdr $version: could not re-read foreign draft"
  [ "$foreign_after" = "$foreign_before" ] || fail "Herdr $version: ring changed or submitted foreign draft"
  [ -f "$safety_rec" ] && [ ! -f "$safety_handled" ] && [ ! -e "$prefix/unsafe-acted" ] \
    || fail "Herdr $version: foreign draft was submitted or durable record was consumed"
  pass "Herdr $version: foreign draft stayed unchanged and unsubmitted"
)

# The portable behavior suite demonstrates that the historical implementation
# fails the swallowed-doorbell case. This live guard owns only real-product
# evidence for the two affected Herdr releases.
# shellcheck source=/dev/null
. "$ROOT/bin/fm-task-inbox-lib.sh"

for version in 0.8.2 0.9.0; do
  prefix=$(mktemp -d "/tmp/fmh${version//./}.XXXXXX") || fail "Herdr $version: could not allocate short scratch prefix"
  if ! obtain_version "$version" "$prefix"; then
    printf '# unavailable: Herdr %s pinned official binary could not be obtained\n' "$version" >&2
    rm -rf "$prefix"
    UNAVAILABLE=$((UNAVAILABLE + 1))
    continue
  fi
  if run_version "$version" "$prefix"; then
    CHECKED=$((CHECKED + 1))
  else
    fail "Herdr $version: live doorbell scenarios failed"
  fi
done

[ "$CHECKED" -gt 0 ] || fail "cross-version Herdr doorbell guard verified no version"
pass "cross-version Herdr doorbell guard: $CHECKED version(s) passed, $UNAVAILABLE unavailable"
