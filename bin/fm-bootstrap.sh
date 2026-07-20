#!/usr/bin/env bash
# Bootstrap detection, best-effort fleet refresh/prune, and installs.
# Usage: fm-bootstrap.sh
#          Detect: prints one line per actionable problem, or an explicit
#          BOOTSTRAP_INFO no-action fact for completed benign bootstrap work, and
#          exits 0.
#          Silent = all good.
#          Lines: "MISSING: <tool> (install: <command>)",
#                 "MISSING_MANUAL: <tool> (instructions: <url>)", "NEEDS_GH_AUTH",
#                 "BACKEND_INVALID: <name> (known: <names>)",
#                 "CREW_DISPATCH: invalid config/crew-dispatch.json - <reason>",
#                 "FLEET_SYNC: <repo>: skipped|recovered|STUCK: <detail>",
#                 "PR_CHECK_MIGRATION: <private remediation>",
#                 "TANGLE: <remediation>",
#                 "SECONDMATE_SYNC: secondmate <id>: skipped: <reason>",
#                 "NUDGE_SECONDMATES: secondmate <id>: send failed: <reason>",
#                 "BOOTSTRAP_INFO: nudged fm-<id> with '<message>'",
#                 "SECONDMATE_LIVENESS: secondmate <id>: skipped: <reason>|respawn failed: <reason>",
#                 "FMX: X mode on ..." or "FMX: X mode off ...".
#          When a RUNNING secondmate worktree is fast-forwarded to firstmate's
#          own current default-branch commit (a purely LOCAL fast-forward, never
#          an origin fetch) AND its loaded instruction surface (AGENTS.md, bin/,
#          or .agents/skills/) actually changed, bootstrap immediately nudges it
#          via FM_HOME=<active-home> bin/fm-send.sh fm-<id> so meta resolves the
#          current backend target and the standard from-firstmate marker is
#          applied. A successful send prints one BOOTSTRAP_INFO line with the
#          exact target and message sent; a failed send leaves an idempotent
#          retry marker under state/.secondmate-nudge-pending/ and prints an
#          actionable NUDGE_SECONDMATES line.
#          Already-current or no-instruction-change homes are silently left alone.
#          The secondmate sweep also propagates declared inherited local material
#          into each validated live secondmate home.
#          SECONDMATE_SYNC lines report actionable skipped local-HEAD syncs or
#          inheritance failures for live secondmate homes, plus quarantine
#          diagnostics for divergent shared captain-preference copies;
#          no-op/current and successful updates stay quiet.
#          SECONDMATE_LIVENESS lines report only actionable failures from the
#          deeper agent-liveness verdict (bin/fm-backend.sh's
#          fm_backend_agent_alive, distinct from endpoint pane-presence):
#          skipped means the probe could not confidently classify the endpoint,
#          and respawn failed means relaunch did not complete. Already-live and
#          successfully respawned secondmates are silent.
#          A TANGLE line means the firstmate primary checkout (FM_ROOT) is stranded
#          on a feature branch instead of its default branch - a crewmate's work
#          landed in the primary instead of its own worktree; restore it per the line.
#          treehouse is also MISSING when its installed version lacks
#          "treehouse get --lease" support.
#          no-mistakes is also MISSING when its installed version is older than
#          1.31.2.
#          tasks-axi and quota-axi are required bootstrap tools (same class as
#          lavish-axi). tasks-axi is also version and feature gated (0.1.1+
#          with update --archive-body and mv [<id>...]); an installed but
#          incompatible build reports MISSING like no-mistakes. A compatible
#          tasks-axi default backend is silent. quota-axi is required because
#          crew-dispatch quota-balanced may call it; fm-dispatch-select.sh still
#          degrades at runtime when quota data is unavailable.
#          X mode is OPTIONAL and inert unless FM_HOME/.env has a non-empty
#          FMX_PAIRING_TOKEN. When opted in, bootstrap requires curl+jq, writes
#          the relay poll shim and 30s cadence config, and prints an FMX line.
#          Fleet sync fetches, fast-forwards safe default-branch states, reports
#          recovered and STUCK clone drift, and prunes gone local branches; it is
#          bounded by FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT when it is a non-empty
#          numeric override, while non-numeric values fall back to 20s.
#          When the override is unset or blank, the timeout is
#          max(20, 5 + 3 * origin-backed project clone count). A timed-out
#          refresh relays any completed fm-fleet-sync.sh output before the
#          aggregate timeout skip line with timeout and elapsed seconds.
#          Set FM_FLEET_PRUNE=0 to skip branch pruning during that refresh.
#          Set FM_BOOTSTRAP_DETECT_ONLY=1 to skip the five MUTATING sweeps
#          (PR-check migration, secondmate_sync, secondmate_liveness_sweep,
#          x_mode_setup, fleet_sync) while still printing every read-only detect line
#          above; the TANGLE line switches to advisory-only wording with no
#          checkout command. Used by
#          fm-session-start.sh's read-only path when another live session holds
#          the fleet lock, so a second concurrent session never race-mutates
#          PR-check artifacts, secondmate homes, X-mode artifacts, project
#          clones, or repair instructions.
#          Unset/0 (the default) runs every sweep exactly as before - this flag
#          is purely additive.
#        fm-bootstrap.sh install <tool>...
#          Install the named tools (only ones the captain approved).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-tangle-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tangle-lib.sh"
# shellcheck source=bin/fm-ff-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-config-inherit-lib.sh"
# shellcheck source=bin/fm-x-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-x-lib.sh"
# shellcheck source=bin/fm-backend.sh disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"

fleet_sync_origin_backed_project_count() {
  local count proj
  count=0
  [ -d "$PROJECTS" ] || { echo 0; return 0; }
  for proj in "$PROJECTS"/*; do
    [ -d "$proj" ] || continue
    git -C "$proj" rev-parse --git-dir >/dev/null 2>&1 || continue
    git -C "$proj" remote get-url origin >/dev/null 2>&1 || continue
    count=$((count + 1))
  done
  echo "$count"
}

fleet_sync_bootstrap_timeout() {
  local count timeout
  if [ -n "${FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT:-}" ]; then
    case "$FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT" in
      *[!0-9]*) echo 20 ;;
      *) echo "$FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT" ;;
    esac
    return 0
  fi

  count=$(fleet_sync_origin_backed_project_count)
  timeout=$((5 + (3 * count)))
  [ "$timeout" -ge 20 ] || timeout=20
  echo "$timeout"
}

fleet_sync_relay_filtered_output() {
  local tmp=$1 line
  while IFS= read -r line; do
    case "$line" in
      *': skipped: local-only project') ;;
      *': skipped: no origin remote') ;;
      *': skipped:'*) echo "FLEET_SYNC: $line" ;;
      *': STUCK:'*) echo "FLEET_SYNC: $line" ;;
      *': recovered:'*) echo "FLEET_SYNC: $line" ;;
    esac
  done < "$tmp"
}

fleet_sync_relay_all_output() {
  local tmp=$1 line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    echo "FLEET_SYNC: $line"
  done < "$tmp"
}

fleet_sync() {
  [ -x "$FM_ROOT/bin/fm-fleet-sync.sh" ] || return 0
  [ -d "$PROJECTS" ] || return 0

  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-fleet-sync.XXXXXX" 2>/dev/null) || return 0
  timeout=$(fleet_sync_bootstrap_timeout)
  monitor_was_on=0
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m 2>/dev/null || true
  "$FM_ROOT/bin/fm-fleet-sync.sh" >"$tmp" 2>/dev/null &
  pid=$!

  start=$SECONDS
  while jobs -r -p | grep -qx "$pid"; do
    elapsed=$((SECONDS - start))
    if [ "$elapsed" -ge "$timeout" ]; then
      kill -TERM "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
      fleet_sync_relay_all_output "$tmp"
      echo "FLEET_SYNC: fleet: skipped: bootstrap refresh timed out (timeout=${timeout}s elapsed=${elapsed}s)"
      rm -f "$tmp"
      return 0
    fi
    sleep 1
  done
  wait "$pid" 2>/dev/null || true
  [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true

  fleet_sync_relay_filtered_output "$tmp"
  rm -f "$tmp"
}

secondmate_sync() {
  # Local-HEAD secondmate sync: fast-forward every LIVE secondmate home
  # to the primary checkout's current default-branch commit. Purely LOCAL - no
  # fetch, no origin dependency: a linked-worktree home already holds the primary's
  # commit (fm-ff-lib.sh), while a standalone clone without it is skipped until
  # /updatefirstmate refreshes it from origin. Startup sends reread nudges only
  # for RUNNING secondmates whose instruction surface (AGENTS.md, bin/, or
  # .agents/skills/) actually changed, so a secondmate already on the primary's
  # version is never disturbed (AGENTS.md bootstrap + supervision). Unlike
  # /updatefirstmate, startup owns the live-convergence send itself because it is
  # a deterministic locked sweep and can report success as BOOTSTRAP_INFO while
  # preserving failed sends as NUDGE_SECONDMATES retry markers.
  [ -d "$STATE" ] || return 0
  local primary_head
  if ! primary_head=$(primary_head_commit "$FM_ROOT"); then
    local meta id
    for meta in "$STATE"/*.meta; do
      [ -f "$meta" ] || continue
      grep -q '^kind=secondmate' "$meta" 2>/dev/null || continue
      id=$(basename "$meta" .meta)
      echo "SECONDMATE_SYNC: secondmate $id: skipped: primary default-branch commit cannot be resolved"
    done
    return 0
  fi
  FF_NUDGE_WINDOWS=""
  FF_SEEN_HOMES=""
  SECOND_MATE_NUDGE_MESSAGE='firstmate was updated to the latest - please re-read your AGENTS.md to pick up the new instructions.'
  SECOND_MATE_NUDGE_PENDING_DIR="$STATE/.secondmate-nudge-pending"

  secondmate_nudge_marker_path() {
    case "$1" in
      *[!/A-Za-z0-9._-]*|""|*/*) return 1 ;;
    esac
    printf '%s/%s.pending' "$SECOND_MATE_NUDGE_PENDING_DIR" "$1"
  }

  secondmate_write_nudge_marker() {
    local id=$1 home=$2 commit=$3 instr=$4 selector marker tmp parent
    selector="fm-$id"
    marker=$(secondmate_nudge_marker_path "$id") || return 1
    parent=${marker%/*}
    mkdir -p "$parent" || return 1
    tmp=$(mktemp "$parent/.nudge.XXXXXX" 2>/dev/null) || return 1
    {
      printf 'id=%s\n' "$id"
      printf 'selector=%s\n' "$selector"
      printf 'home=%s\n' "$home"
      printf 'commit=%s\n' "$commit"
      printf 'instructions=%s\n' "$instr"
      printf 'message=%s\n' "$SECOND_MATE_NUDGE_MESSAGE"
    } > "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$marker" || { rm -f "$tmp"; return 1; }
  }

  secondmate_send_nudge() {
    local id=$1 home=$2 commit=$3 instr=$4 selector marker out
    selector="fm-$id"
    marker=$(secondmate_nudge_marker_path "$id") || {
      echo "NUDGE_SECONDMATES: secondmate $id: send failed: unsafe id"
      return 0
    }
    if ! secondmate_write_nudge_marker "$id" "$home" "$commit" "$instr"; then
      echo "NUDGE_SECONDMATES: secondmate $id: send failed: cannot record retry marker"
      return 0
    fi
    if out=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-send.sh" "$selector" "$SECOND_MATE_NUDGE_MESSAGE" 2>&1); then
      rm -f "$marker"
      echo "BOOTSTRAP_INFO: nudged $selector with '$SECOND_MATE_NUDGE_MESSAGE'"
    else
      echo "NUDGE_SECONDMATES: secondmate $id: send failed: $(first_line "$out")"
    fi
  }

  fm_ff_after_instruction_update() {
    local id=$1 home=$2 _window=$3 instr=$4
    secondmate_send_nudge "$id" "$home" "$primary_head" "$instr"
  }

  secondmate_retry_pending_nudges() {
    local marker id selector home commit message expected_marker meta meta_home home_real head
    [ -d "$SECOND_MATE_NUDGE_PENDING_DIR" ] || return 0
    for marker in "$SECOND_MATE_NUDGE_PENDING_DIR"/*.pending; do
      [ -f "$marker" ] || continue
      id=$(fm_meta_get "$marker" id)
      if ! expected_marker=$(secondmate_nudge_marker_path "$id"); then
        echo "NUDGE_SECONDMATES: secondmate ${id:-unknown}: send failed: retry marker has unsafe id"
        continue
      fi
      [ "$expected_marker" = "$marker" ] || {
        echo "NUDGE_SECONDMATES: secondmate $id: send failed: retry marker filename mismatch"
        continue
      }
      selector=$(fm_meta_get "$marker" selector)
      home=$(fm_meta_get "$marker" home)
      commit=$(fm_meta_get "$marker" commit)
      message=$(fm_meta_get "$marker" message)
      [ "$selector" = "fm-$id" ] || {
        echo "NUDGE_SECONDMATES: secondmate ${id:-unknown}: send failed: retry marker selector mismatch"
        continue
      }
      [ "$message" = "$SECOND_MATE_NUDGE_MESSAGE" ] || {
        echo "NUDGE_SECONDMATES: secondmate ${id:-unknown}: send failed: retry marker message mismatch"
        continue
      }
      meta="$STATE/$id.meta"
      [ -f "$meta" ] && [ "$(fm_meta_get "$meta" kind)" = secondmate ] || {
        echo "NUDGE_SECONDMATES: secondmate ${id:-unknown}: send failed: retry target has no live secondmate metadata"
        continue
      }
      meta_home=$(fm_meta_get "$meta" home)
      [ -n "$meta_home" ] || meta_home=$(secondmate_registry_field "$DATA/secondmates.md" "$id" home || true)
      if ! validate_secondmate_home "$id" "$meta_home"; then
        echo "NUDGE_SECONDMATES: secondmate $id: send failed: retry target home unsafe: $VALIDATION_ERROR"
        continue
      fi
      home_real="$VALIDATED_HOME"
      [ "$home_real" = "$home" ] || {
        echo "NUDGE_SECONDMATES: secondmate $id: send failed: retry target home changed"
        continue
      }
      head=$(git -C "$home_real" rev-parse HEAD 2>/dev/null || true)
      [ -n "$head" ] && [ "$head" = "$commit" ] || {
        echo "NUDGE_SECONDMATES: secondmate $id: send failed: retry target is not at recorded instruction commit"
        continue
      }
      if out=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-send.sh" "$selector" "$SECOND_MATE_NUDGE_MESSAGE" 2>&1); then
        rm -f "$marker"
        echo "BOOTSTRAP_INFO: nudged $selector with '$SECOND_MATE_NUDGE_MESSAGE'"
      else
        echo "NUDGE_SECONDMATES: secondmate $id: send failed: $(first_line "$out")"
      fi
    done
  }

  local tmp line
  secondmate_retry_pending_nudges
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-secondmate-sync.XXXXXX" 2>/dev/null) || return 0
  sweep_live_secondmate_metas "$STATE" "$primary_head" yes "$DATA/secondmates.md" >"$tmp"
  while IFS= read -r line; do
    case "$line" in
      secondmate\ *': skipped:'*) echo "SECONDMATE_SYNC: $line" ;;
      BOOTSTRAP_INFO:\ *) echo "$line" ;;
      NUDGE_SECONDMATES:\ *) echo "$line" ;;
    esac
  done < "$tmp"
  rm -f "$tmp"
  unset -f fm_ff_after_instruction_update
  # Inheritance propagation: push the primary-authoritative local inheritance
  # surface into every VALIDATED live secondmate home swept above.
  # FF_SEEN_HOMES is exactly that set, and fm-config-inherit-lib.sh owns the
  # declared config items plus data/captain-shared.md.
  local id home home_real propagated_homes
  propagated_homes=""
  while IFS='|' read -r id home _window _meta; do
    validate_secondmate_home "$id" "$home" || continue
    home_real="$VALIDATED_HOME"
    case " $FF_SEEN_HOMES " in
      *" $home_real "*) ;;
      *) continue ;;
    esac
    case " $propagated_homes " in
      *" $home_real "*) continue ;;
    esac
    propagated_homes="$propagated_homes $home_real"
    if ! propagate_secondmate_inheritance "$FM_HOME" "$home_real" "$CONFIG" "$DATA"; then
      echo "SECONDMATE_SYNC: secondmate $id: skipped: inheritance failed"
    fi
  done < <(live_secondmate_meta_records "$STATE" "$DATA/secondmates.md")
  return 0
}

secondmate_liveness_sweep() {
  # Idempotent secondmate liveness guarantee - SESSION START ONLY. A
  # secondmate agent that has exited leaves its backend endpoint alive as a
  # bare shell; the session-start digest's "endpoint: alive" read
  # (fm_backend_target_exists, pane-PRESENCE only) reports that shell as
  # alive, so recovery never respawns it, and the watcher deliberately exempts
  # secondmates from stale-pane detection (an idle secondmate pane is healthy
  # by design). Evidence 2026-07-07: every secondmate in this fleet was found
  # as a dead zsh shell, invisible to every existing check. This sweep closes
  # the gap deterministically: for every LIVE secondmate meta (kind=secondmate
  # with a recorded window=), run the deeper fm_backend_agent_alive probe
  # (bin/fm-backend.sh) and act only on a CONFIDENT verdict:
  #   alive   - no-op.
  #   dead    - kill the stale endpoint first (best-effort; the tmux adapter
  #             refuses to create a same-named window over a live one) then
  #             respawn via the existing recovery path (bin/fm-spawn.sh <id>
  #             --secondmate; secondmate-provisioning).
  #   unknown - NEVER acted on. A false-dead reading would spin up a DUPLICATE
  #             agent (two supervisors in one home); a false-alive reading
  #             merely leaves today's bug unfixed for one more sweep. The
  #             worse direction is guarded by never treating anything less
  #             than a confident dead reading as license to respawn.
  # A meta with no recorded window= at all is left to the existing "meta with
  # no window" recovery path (AGENTS.md section 5 / secondmate-provisioning);
  # there is no endpoint here for this probe to read.
  # Naturally scoped to the primary: a secondmate's own state/ never holds
  # kind=secondmate metas (secondmates never spawn secondmates), so this
  # sweep is a silent no-op there, exactly like secondmate_sync above.
  # Scope: session start (reboot/restart) only. A secondmate dying
  # MID-SESSION is a harder follow-on needing a periodic liveness beacon -
  # explicitly out of scope here.
  [ -d "$STATE" ] || return 0
  local meta id window harness backend target verdict out
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    grep -q '^kind=secondmate$' "$meta" 2>/dev/null || continue
    id=$(basename "$meta" .meta)
    window=$(fm_meta_get "$meta" window)
    [ -n "$window" ] || continue
    harness=$(fm_meta_get "$meta" harness)
    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")
    [ -n "$target" ] || target="$window"
    verdict=$(fm_backend_agent_alive "$backend" "$target" 2>/dev/null) || verdict="unknown"
    case "$harness" in
      claude|codex|opencode|pi|grok) ;;
      *) [ "$verdict" = dead ] && verdict=unknown ;;
    esac
    case "$verdict" in
      alive)
        ;;
      dead)
        fm_backend_kill "$backend" "$target" 2>/dev/null || true
        if out=$(FM_SPAWN_NO_GUARD=1 "$FM_ROOT/bin/fm-spawn.sh" "$id" --secondmate 2>&1); then
          :
        else
          echo "SECONDMATE_LIVENESS: secondmate $id: respawn failed: $(first_line "$out")"
        fi
        ;;
      *)
        echo "SECONDMATE_LIVENESS: secondmate $id: skipped: liveness probe inconclusive (backend=$backend)"
        ;;
    esac
  done
  return 0
}

install_cmd() {
  case "$1" in
    tmux|node|git|gh|curl|jq|orca|zellij) echo "brew install $1  # or the platform's package manager" ;;
    cmux) echo "brew install --cask cmux  # or see https://cmux.com" ;;
    treehouse) echo "curl -fsSL https://kunchenguid.github.io/treehouse/install.sh | sh" ;;
    no-mistakes) echo "curl -fsSL https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh | sh" ;;
    gh-axi|chrome-devtools-axi|lavish-axi) echo "npm install -g $1 && $1 setup hooks" ;;
    tasks-axi|quota-axi) echo "npm install -g $1" ;;
    *) return 1 ;;
  esac
}

manual_install_url() {
  case "$1" in
    herdr) echo "https://herdr.dev" ;;
    *) return 1 ;;
  esac
}

missing_tool_diagnostic() {
  local tool=$1 instructions
  if instructions=$(manual_install_url "$tool"); then
    echo "MISSING_MANUAL: $tool (instructions: $instructions)"
    return 0
  fi
  echo "MISSING: $tool (install: $(install_cmd "$tool"))"
}

# Required-tool detection follows the RESOLVED backend, not a one-size default:
# a universal toolchain every home needs plus the backend-specific delta owned by
# fm_backend_required_tools (bin/fm-backend.sh). So a herdr/zellij/cmux home is
# never told tmux is missing, and only orca drops treehouse. A backend value with
# no verified dependency set is reported before the universal checks continue.
COMMON_TOOLS="node git gh no-mistakes gh-axi chrome-devtools-axi lavish-axi tasks-axi quota-axi"
BACKEND=$(fm_backend_name)
BACKEND_VALID=1
if ! BACKEND_TOOLS=$(fm_backend_required_tools "$BACKEND"); then
  BACKEND_VALID=0
  BACKEND_TOOLS=""
fi
TOOLS="$BACKEND_TOOLS $COMMON_TOOLS"
NO_MISTAKES_MIN_MAJOR=1
NO_MISTAKES_MIN_MINOR=31
NO_MISTAKES_MIN_PATCH=2

treehouse_supports_lease() {
  treehouse get --help 2>&1 | grep -Eq '(^|[^[:alnum:]_-])--lease([^[:alnum:]_-]|$)'
}

no_mistakes_version_parts() {
  local output
  command -v no-mistakes >/dev/null 2>&1 || return 1
  output=$(no-mistakes --version 2>/dev/null) || return 1
  printf '%s\n' "$output" | sed -nE 's/.*[vV]?([0-9]+)\.([0-9]+)\.([0-9]+).*/\1 \2 \3/p' | head -n 1
}

no_mistakes_compatible() {
  local parts major minor patch extra
  parts=$(no_mistakes_version_parts) || return 1
  IFS=' ' read -r major minor patch extra <<< "$parts"
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || return 1
  [ "$major" -gt "$NO_MISTAKES_MIN_MAJOR" ] && return 0
  [ "$major" -eq "$NO_MISTAKES_MIN_MAJOR" ] || return 1
  [ "$minor" -gt "$NO_MISTAKES_MIN_MINOR" ] && return 0
  [ "$minor" -eq "$NO_MISTAKES_MIN_MINOR" ] || return 1
  [ "$patch" -ge "$NO_MISTAKES_MIN_PATCH" ]
}

x_mode_write_if_changed() {
  local dest=$1 content=$2 mode=$3 parent tmp parent_device current_mode
  parent=${dest%/*}
  [ "$parent" != "$dest" ] || return 1
  [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
  if [ "$(uname)" = Darwin ]; then
    parent_device=$(stat -f %d "$parent" 2>/dev/null) || return 1
  else
    parent_device=$(stat -c %d "$parent" 2>/dev/null) || return 1
  fi
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    fmx_single_link_file_valid "$dest" "$parent_device" || return 1
    if [ "$(uname)" = Darwin ]; then
      current_mode=$(stat -f %Lp "$dest" 2>/dev/null) || return 1
    else
      current_mode=$(stat -c %a "$dest" 2>/dev/null) || return 1
    fi
    if [ "$current_mode" = "$mode" ] && cmp -s "$dest" <(printf '%s\n' "$content"); then
      return 0
    fi
  fi
  tmp=$(umask 077; mktemp "$parent/.fm-x-mode.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$content" > "$tmp" \
    || ! chmod "$mode" "$tmp" \
    || ! fmx_single_link_file_mode_valid "$tmp" "$mode" "$parent_device"; then
    rm -f -- "$tmp"
    return 1
  fi
  if { [ -e "$dest" ] || [ -L "$dest" ]; } \
    && ! fmx_single_link_file_valid "$dest" "$parent_device"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! fmx_single_link_file_mode_valid "$dest" "$mode" "$parent_device" \
    || ! cmp -s "$dest" <(printf '%s\n' "$content"); then
    rm -f -- "$dest"
    return 1
  fi
}

x_mode_artifact_present() {
  [ -e "$1" ] || [ -L "$1" ]
}

x_mode_remove_artifact() {
  local artifact=$1 parent=${1%/*}
  x_mode_artifact_present "$artifact" || return 0
  [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
  rm -f -- "$artifact" 2>/dev/null || return 1
  ! x_mode_artifact_present "$artifact"
}

# X mode (opt-in): when this home's .env carries a non-empty FMX_PAIRING_TOKEN,
# wire the relay poll into the existing authenticated watcher dispatch.
# Drops two idempotent, gitignored artifacts:
#   state/x-watch.check.sh - byte-static identity shim; the watcher validates
#                            its bytes and invokes bin/fm-x-poll.sh directly
#   config/x-mode.env      - exports FM_CHECK_INTERVAL=30, sourced by the watcher
#                            arm so only an X instance polls at the 30s cadence
# On opt-out (no token, or empty) it removes any such artifacts so the instance
# reverts to the default 300s no-poll behavior. Absent a token AND with no leftover
# artifacts it is a complete no-op (nothing written, nothing printed), so a non-X
# user sees zero change. Prints one confirmation line on opt-in, and one on opt-out
# only when it actually removed artifacts. It never touches the watcher itself;
# applying a cadence transition to a running watcher is the caller's job via
# the emitted harness-aware supervision repair instruction.
x_mode_setup() {
  local env_file token shim cadence shim_body cadence_body tool missing
  env_file="$FM_HOME/.env"
  shim="$STATE/x-watch.check.sh"
  cadence="$CONFIG/x-mode.env"

  token=
  [ -f "$env_file" ] && token=$(fmx_env_get FMX_PAIRING_TOKEN "$env_file")

  x_mode_remove_artifacts() {
    local failed=0
    x_mode_remove_artifact "$shim" || failed=1
    x_mode_remove_artifact "$cadence" || failed=1
    [ "$failed" -eq 0 ]
  }

  x_mode_supervision_repair() {
    local out
    out=$("$SCRIPT_DIR/fm-supervision-instructions.sh" --repair-line 2>/dev/null) \
      || out='repair missing watcher supervision according to the session-start operating block.'
    printf '%s\n' "$out"
  }

  if [ -z "$token" ]; then
    # Opt-out (or never opted in): drop any X artifacts; stay silent unless we
    # actually removed something.
    if x_mode_artifact_present "$shim" || x_mode_artifact_present "$cadence"; then
      if x_mode_remove_artifacts; then
        echo "FMX: X mode off - removed relay poll shim and 30s cadence; default cadence applies on the next supervision cycle; $(x_mode_supervision_repair)"
      else
        echo "FMX: X mode off - failed to remove relay poll shim or 30s cadence"
      fi
    fi
    return 0
  fi

  missing=0
  for tool in curl jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "MISSING: $tool (install: $(install_cmd "$tool"))"
      missing=1
    fi
  done
  if [ "$missing" -ne 0 ]; then
    if x_mode_artifact_present "$shim" || x_mode_artifact_present "$cadence"; then
      if x_mode_remove_artifacts; then
        echo "FMX: X mode off - missing relay poll dependencies; install them and rerun bootstrap"
      else
        echo "FMX: X mode off - failed to remove relay poll shim or 30s cadence after missing relay poll dependencies"
      fi
    fi
    return 0
  fi

  fmx_arm_failed() {
    if x_mode_remove_artifacts; then
      echo "FMX: X mode off - failed to arm relay poll shim or 30s cadence"
    else
      echo "FMX: X mode off - failed to arm relay poll shim or 30s cadence; stale artifacts remain"
    fi
  }

  mkdir -p "$STATE" "$CONFIG" 2>/dev/null || { fmx_arm_failed; return 0; }

  shim_body=$(fmx_poll_shim_content "$FM_HOME" "$FM_ROOT")
  x_mode_write_if_changed "$shim" "$shim_body" 700 || { fmx_arm_failed; return 0; }
  fmx_poll_shim_valid "$shim" "$FM_HOME" "$FM_ROOT" \
    || { fmx_arm_failed; return 0; }

  cadence_body=$(cat <<'EOF'
# Auto-generated by fm-bootstrap.sh - X mode watcher cadence.
# Source this before the active harness protocol starts a watcher process so
# fm-watch.sh polls the X check every 30s. Non-X instances have no such file and
# keep the default 300s cadence.
export FM_CHECK_INTERVAL=30
EOF
)
  x_mode_write_if_changed "$cadence" "$cadence_body" 600 || { fmx_arm_failed; return 0; }

  echo "FMX: X mode on - relay poll armed via state/x-watch.check.sh; 30s watcher cadence in config/x-mode.env"
}

crew_dispatch_validate() {
  local file err
  file="$CONFIG/crew-dispatch.json"
  [ -f "$file" ] || return 0
  if ! command -v jq >/dev/null 2>&1; then
    echo "MISSING: jq (install: $(install_cmd jq))"
    return 0
  fi
  if ! jq -e . "$file" >/dev/null 2>&1; then
    echo "CREW_DISPATCH: invalid config/crew-dispatch.json - malformed JSON"
    return 0
  fi
  err=$(jq -r '
    def verified($h): ["claude","codex","opencode","pi","grok"] | index($h);
    def effort_ok($h; $e):
      if $e == null then true
      elif ($e | type) != "string" then false
      elif $h == "claude" then (["low","medium","high","xhigh","max"] | index($e))
      elif $h == "codex" then (["low","medium","high","xhigh"] | index($e))
      elif $h == "grok" then (["low","medium","high"] | index($e))
      elif $h == "pi" then (["low","medium","high","xhigh","max"] | index($e))
      elif $h == "opencode" then false
      else true
      end;
    def use_profiles($u):
      if ($u | type) == "array" then $u
      elif ($u | type) == "object" then [$u]
      else []
      end;
    def bad_efforts:
      ([(.rules // [])[]? | use_profiles(.use?)[]? | {h: .harness, e: .effort}]
        + (if (.default? | type) == "object" then [{h: .default.harness, e: .default.effort}] else [] end))
      | map(select(.e != null))
      | map(select((.h | type) == "string" and verified(.h)))
      | map(select(. as $p | effort_ok($p.h; $p.e) | not))
      | map("\(.h):\(.e)")
      | unique;
    if type != "object" then "top-level value must be an object"
    elif has("rules") and (.rules | type) != "array" then "rules must be an array"
    elif [(.rules // [])[]? | select(type != "object")] | length > 0 then "each rule must be an object"
    elif [(.rules // [])[]? | select((.when? | type) != "string" or (.when | length) == 0)] | length > 0 then "each rule needs non-empty when"
    elif [(.rules // [])[]? | select((.use? | type) != "object" and (.use? | type) != "array")] | length > 0 then "each rule needs use"
    elif [(.rules // [])[]? | select((.use? | type) == "array" and (.use | length) == 0)] | length > 0 then "each rule needs at least one use profile"
    elif [(.rules // [])[]? | use_profiles(.use?)[]? | select(type != "object")] | length > 0 then "each use profile must be an object"
    elif [(.rules // [])[]? | use_profiles(.use?)[]? | select((.harness? | type) != "string" or (.harness | length) == 0)] | length > 0 then "each use profile needs harness"
    elif [(.rules // [])[]? | select(has("select") and ((.select? | type) != "string" or (.select | length) == 0))] | length > 0 then "select must be a non-empty string"
    elif [(.rules // [])[]? | .select? // empty | select(. != "quota-balanced")] | length > 0 then
      "unknown select: " + ([ (.rules // [])[]? | .select? // empty | select(. != "quota-balanced") ] | unique | join(", "))
    elif has("default") and (.default | type) != "object" then "default must be an object"
    elif has("default") and ((.default.harness? | type) != "string" or (.default.harness | length) == 0) then "default needs harness when present"
    else
      ([(.rules // [])[]? | use_profiles(.use?)[]?.harness] + [.default?.harness?]
        | map(select(. != null))
        | map(select(. as $h | verified($h) | not))
        | unique) as $bad_harnesses
      | if ($bad_harnesses | length) > 0 then "unverified harness: " + ($bad_harnesses | join(", "))
        elif (bad_efforts | length) > 0 then "invalid effort: " + (bad_efforts | join(", "))
        else empty
        end
    end
  ' "$file" 2>/dev/null || true)
  if [ -n "$err" ]; then
    echo "CREW_DISPATCH: invalid config/crew-dispatch.json - $err"
    return 0
  fi
  if [ "${FM_BOOTSTRAP_VERBOSE_FACTS:-0}" = 1 ]; then
    jq -r '
    def profile($p):
      ($p.harness | tostring)
      + (if ($p.model? != null) then "/" + ($p.model | tostring)
         elif ($p.effort? != null) then "/default"
         else "" end)
      + (if ($p.effort? != null) then "/" + ($p.effort | tostring) else "" end);
    def use_label($r):
      if ($r.use | type) == "array" then
        ((if ($r.select? != null) then ($r.select | tostring) else "first" end)
          + "[" + ([$r.use[] | profile(.)] | join(", ")) + "]")
      else profile($r.use)
      end;
    (["BOOTSTRAP_INFO: crew dispatch active config/crew-dispatch.json"]
      + [(.rules // [])[]? | "BOOTSTRAP_INFO: crew dispatch rule: " + (.when | tostring) + " -> " + use_label(.)]
      + (if (.default? | type) == "object" then ["BOOTSTRAP_INFO: crew dispatch default: " + profile(.default)] else [] end))
    | .[]
  ' "$file"
  fi
}

if [ "${1:-}" = "install" ]; then
  shift
  [ $# -gt 0 ] || { echo "usage: fm-bootstrap.sh install <tool>..." >&2; exit 1; }
  for t in "$@"; do
    if ! cmd=$(install_cmd "$t"); then
      instructions=$(manual_install_url "$t") || { echo "error: unknown tool $t" >&2; exit 1; }
      echo "error: $t requires manual installation (instructions: $instructions)" >&2
      exit 1
    fi
    cmd=${cmd%%  #*}
    echo "installing $t: $cmd"
    eval "$cmd"
  done
  exit 0
fi

# This is the first mutating sweep at a locked session boundary. It pauses an
# identity-matched watcher, holds its lock, and neutralizes legacy PR checks
# before any tool detection or later bootstrap mutation can leave old artifacts
# runnable. Detect-only sessions never touch state.
if [ "${FM_BOOTSTRAP_DETECT_ONLY:-0}" != 1 ]; then
  "$SCRIPT_DIR/fm-pr-check-migrate.sh" || true
fi

if [ "$BACKEND_VALID" -eq 0 ]; then
  echo "BACKEND_INVALID: $BACKEND (known: $FM_BACKEND_KNOWN)"
fi
for t in $BACKEND_TOOLS; do
  fm_backend_required_tool_available "$BACKEND" "$t" \
    || missing_tool_diagnostic "$t"
done
for t in $COMMON_TOOLS; do
  command -v "$t" >/dev/null || missing_tool_diagnostic "$t"
done
# The treehouse lease-support upgrade check is only relevant when the resolved
# backend actually requires treehouse (every backend except orca, which owns its
# own worktrees); an orca home must not be told to upgrade a provider it never uses.
if fm_backend_list_contains "$TOOLS" treehouse \
  && command -v treehouse >/dev/null 2>&1 && ! treehouse_supports_lease; then
  echo "MISSING: treehouse (install: $(install_cmd treehouse))"
fi
if command -v no-mistakes >/dev/null 2>&1 && ! no_mistakes_compatible; then
  echo "MISSING: no-mistakes (install: $(install_cmd no-mistakes))"
fi
if command -v tasks-axi >/dev/null 2>&1 && ! fm_tasks_axi_compatible; then
  echo "MISSING: tasks-axi (install: $(install_cmd tasks-axi))"
fi
gh auth status >/dev/null 2>&1 || echo "NEEDS_GH_AUTH"
# Worktree-tangle check: the firstmate primary checkout (FM_ROOT) must sit on its
# default branch, not a feature branch (see fm-tangle-lib.sh). Scoped to the
# primary only; detached-HEAD worktrees and secondmate homes never trip it.
tangle_branch=$(fm_primary_tangle_branch "$FM_ROOT" 2>/dev/null || true)
if [ -n "$tangle_branch" ]; then
  tangle_default=$(fm_default_branch "$FM_ROOT" 2>/dev/null || echo main)
  if [ "${FM_BOOTSTRAP_DETECT_ONLY:-0}" = 1 ]; then
    echo "TANGLE: primary checkout on feature branch '$tangle_branch' (expected '$tangle_default'); the work is safe on that ref - read-only session must leave restore work to the session holding the fleet lock"
  else
    echo "TANGLE: primary checkout on feature branch '$tangle_branch' (expected '$tangle_default'); the work is safe on that ref - restore the primary with: git -C $FM_ROOT checkout $tangle_default, then re-validate the branch in a proper worktree"
  fi
fi
crew=
[ -f "$CONFIG/crew-harness" ] && crew=$(tr -d '[:space:]' < "$CONFIG/crew-harness" || true)
if [ "${FM_BOOTSTRAP_VERBOSE_FACTS:-0}" = 1 ] && [ -n "$crew" ] && [ "$crew" != "default" ]; then
  echo "BOOTSTRAP_INFO: crew harness override active: $crew"
fi
crew_dispatch_validate
if [ "${FM_BOOTSTRAP_VERBOSE_FACTS:-0}" = 1 ] \
  && ! fm_backlog_backend_manual "$CONFIG" && fm_tasks_axi_compatible; then
  echo "BOOTSTRAP_INFO: tasks-axi available"
fi
if [ "${FM_BOOTSTRAP_DETECT_ONLY:-0}" != 1 ]; then
  secondmate_sync
  secondmate_liveness_sweep
  x_mode_setup
  fleet_sync
fi
exit 0
