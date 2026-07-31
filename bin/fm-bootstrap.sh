#!/usr/bin/env bash
# Bootstrap detection, best-effort fleet refresh/prune, and installs.
# Usage: fm-bootstrap.sh
#          Detect: prints one line per problem or capability fact and exits 0.
#          Silent = all good.
#          Lines: "MISSING: <tool> (install: <command>)",
#                 "MISSING_MANUAL: <tool> (instructions: <url>)", "NEEDS_GH_AUTH",
#                 "BACKEND_INVALID: <name> (known: <names>)",
#                 "ACCOUNT_ROUTING: invalid routing policy - <reason>",
#                 "CREW_HARNESS_OVERRIDE: <name>",
#                 "CREW_DISPATCH: invalid config/crew-dispatch.json - <reason>",
#                 "CREW_DISPATCH: active config/crew-dispatch.json" plus indented rules,
#                 "FLEET_SYNC: <repo>: skipped|recovered|STUCK: <detail>",
#                 "MISSING: checkout-refresh (install: bin/fm-bootstrap.sh install checkout-refresh)",
#                 "TASKS_AXI: available", "TANGLE: <remediation>",
#                 "SECONDMATE_SYNC: secondmate <id>: skipped: <reason>",
#                 "NUDGE_SECONDMATES: fm-<id>...",
#                 "REPORT_RETENTION: unavailable: <reason>",
#                 "SECONDMATE_LIVENESS: secondmate <id>: <outcome>",
#                 "FMX: X mode on ..." or "FMX: X mode off ...".
#          A NUDGE_SECONDMATES line lists the RUNNING secondmate task selectors
#          (fm-<id>) whose worktree was fast-forwarded to firstmate's own
#          current default-branch commit (a purely LOCAL fast-forward, never an
#          origin fetch) AND whose instruction surface (AGENTS.md, bin/, or
#          .agents/skills/) actually changed; firstmate nudges each via
#          bin/fm-send.sh fm-<id> so meta resolves the current backend target
#          even when the same bootstrap run also respawned the secondmate.
#          Already-current or no-instruction-change homes are silently left alone.
#          The secondmate sweep also propagates declared inheritable local config
#          into each validated live secondmate home.
#          SECONDMATE_SYNC lines report actionable skipped local-HEAD syncs or
#          config-inheritance failures for live secondmate homes; no-op/current
#          and successful updates stay quiet.
#          SECONDMATE_LIVENESS lines report every live secondmate's deeper
#          agent-liveness verdict (bin/fm-backend.sh's fm_backend_agent_alive,
#          distinct from the endpoint pane-presence check): outcomes distinguish
#          no-op, successful respawn, explicit-routing deferral, skipped
#          recovery, and failed recovery. A confirmed-dead unmanaged generation
#          is deferred until an operator chooses whether to preserve
#          unmanaged routing or convert it to managed routing. Session-start scope only;
#          see AGENTS.md "Session start" and docs/tmux-backend.md /
#          docs/herdr-backend.md "Agent liveness probe" for the empirical basis.
#          A TANGLE line means the firstmate primary checkout (FM_ROOT) is stranded
#          on a feature branch instead of its default branch - a crewmate's work
#          landed in the primary instead of its own worktree; restore it per the line.
#          treehouse is also MISSING when its installed version lacks
#          "treehouse get --lease" support.
#          no-mistakes is also MISSING when its installed version is older than
#          1.31.2.
#          tasks-axi and quota-axi are required bootstrap tools (same class as
#          lavish-axi). tasks-axi is also version and feature gated (0.1.1+
#          with update --archive-body and mv [<id>...]); an installed but incompatible build
#          reports MISSING like no-mistakes. When
#          config/backlog-backend is not manual and tasks-axi is compatible,
#          bootstrap prints TASKS_AXI: available. quota-axi is required because
#          crew-dispatch quota-balanced may call it; fm-dispatch-select.sh still
#          degrades at runtime when quota data is unavailable.
#          Routed direct crew selection also requires Agent Fleet's read-only
#          profile registry so pool-reserved accounts can fail closed.
#          X mode is OPTIONAL and inert unless FM_HOME/.env has a non-empty
#          FMX_PAIRING_TOKEN. When opted in, bootstrap requires curl+jq, writes
#          the relay poll shim and 30s cadence config, and prints an FMX line.
#          Fleet sync discovers projects/, Treehouse backing checkouts,
#          configured checkouts, and matching-origin top-level clones, then
#          fetches and fast-forwards safe default-branch states and reports
#          recovered and STUCK clone drift, incomplete discovery, invalid
#          coverage configuration, and untracked skill-draft hygiene.
#          Session-start refresh keeps the existing gone-branch prune behavior;
#          the independent checkout-refresh cadence disables pruning, while
#          this session-start invocation passes --session to preserve it.
#          The cadence needs the checkout-refresh background service installed
#          with explicit captain approval through the MISSING diagnostic.
#          Session-start fleet sync is
#          bounded by FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT when it is a non-empty
#          numeric override, while non-numeric values fall back to 20s.
#          When the override is unset or blank, the timeout is
#          max(20, 5 + 3 * origin-backed project clone count). A timed-out
#          refresh relays any completed fm-fleet-sync.sh output before the
#          aggregate timeout skip line with timeout and elapsed seconds.
#          Set FM_FLEET_PRUNE=0 to skip branch pruning during that refresh.
#          Set FM_BOOTSTRAP_DETECT_ONLY=1 to skip the five MUTATING sweeps
#          (report_retention_ensure, secondmate_sync,
#          secondmate_liveness_sweep, x_mode_setup, fleet_sync) while still
#          printing every read-only detect line
#          above; the TANGLE line switches to advisory-only wording with no
#          checkout command. Used by
#          fm-session-start.sh's read-only path when another live session holds
#          the fleet lock, so a second concurrent session never race-mutates
#          report-retention installation state, secondmate homes, X-mode
#          artifacts, covered checkouts, or repair instructions. Unset/0 (the
#          default) runs every sweep exactly as before - this flag is purely
#          additive.
#        fm-bootstrap.sh install <tool>...
#          Install the named tools (only ones the captain approved).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
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
# shellcheck source=bin/fm-account-routing-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-account-routing-lib.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent

report_retention_ensure() {
  local out
  if [ "${FM_GATE_REFUSE_BYPASS:-0}" = 1 ] && [ -z "${FM_REPORT_STACK_ROOT:-}" ]; then
    return 0
  fi
  if ! out=$("$SCRIPT_DIR/fm-report-retention.sh" ensure 2>&1); then
    [ -n "$out" ] || out="persistent owner did not start"
    echo "REPORT_RETENTION: unavailable: ${out%%$'\n'*}"
  fi
}

checkout_refresh_ensure() {
  local out
  [ "$(uname)" = Darwin ] || return 0
  [ -x "$SCRIPT_DIR/fm-checkout-refresh.sh" ] || return 0
  if [ "${FM_GATE_REFUSE_BYPASS:-0}" = 1 ] && [ "${FM_CHECKOUT_REFRESH_BOOTSTRAP_TEST:-0}" != 1 ]; then
    return 0
  fi
  if ! out=$("$SCRIPT_DIR/fm-checkout-refresh.sh" ensure 2>&1); then
    [ -n "$out" ] || out="background owner did not start"
    echo "MISSING: checkout-refresh (install: bin/fm-bootstrap.sh install checkout-refresh)"
    echo "FLEET_SYNC: background: skipped: ${out%%$'\n'*}"
  fi
}

fleet_sync_origin_backed_project_count() {
  local count proj
  if [ -x "$FM_ROOT/bin/fm-checkout-refresh.sh" ] \
    && { [ "${FM_GATE_REFUSE_BYPASS:-0}" != 1 ] || [ "${FM_CHECKOUT_REFRESH_BOOTSTRAP_TEST:-0}" = 1 ]; }; then
    count=$("$FM_ROOT/bin/fm-checkout-refresh.sh" discover 2>/dev/null | awk 'NF { n += 1 } END { print n + 0 }')
    echo "$count"
    return 0
  fi
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
      *': HYGIENE:'*) echo "FLEET_SYNC: $line" ;;
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

  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-fleet-sync.XXXXXX" 2>/dev/null) || return 0
  timeout=$(fleet_sync_bootstrap_timeout)
  monitor_was_on=0
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m 2>/dev/null || true
  if [ -x "$FM_ROOT/bin/fm-checkout-refresh.sh" ] \
    && { [ "${FM_GATE_REFUSE_BYPASS:-0}" != 1 ] || [ "${FM_CHECKOUT_REFRESH_BOOTSTRAP_TEST:-0}" = 1 ]; }; then
    "$FM_ROOT/bin/fm-checkout-refresh.sh" run-once --force --verbose --session >"$tmp" 2>&1 &
  else
    [ -d "$PROJECTS" ] || { rm -f "$tmp"; return 0; }
    "$FM_ROOT/bin/fm-fleet-sync.sh" >"$tmp" 2>/dev/null &
  fi
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
  # /updatefirstmate refreshes it from origin. Emits NUDGE_SECONDMATES:
  # only for RUNNING secondmates whose instruction surface (AGENTS.md, bin/, or
  # .agents/skills/) actually changed, so a secondmate already on the primary's
  # version is never disturbed (AGENTS.md bootstrap + supervision). Mirrors
  # fm-update's nudge-secondmates: report so firstmate can live-converge the
  # listed fm-<id> selectors.
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
  local tmp line
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-secondmate-sync.XXXXXX" 2>/dev/null) || return 0
  sweep_live_secondmate_metas "$STATE" "$primary_head" yes >"$tmp"
  while IFS= read -r line; do
    case "$line" in
      secondmate\ *': skipped:'*) echo "SECONDMATE_SYNC: $line" ;;
    esac
  done < "$tmp"
  rm -f "$tmp"
  # Inheritable-config propagation: push the primary's declared LOCAL config
  # into every VALIDATED live secondmate home swept
  # above (FF_SEEN_HOMES is exactly that set). config/ is gitignored, so this is a
  # separate copy from the tracked-files fast-forward; primary-authoritative, so
  # it runs whether or not the home's tracked files advanced, keeping the fleet
  # converged on the primary. The propagation helper stays silent on success; a
  # primary with no inheritable config set and no downstream copy is a no-op.
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
    if ! propagate_inheritable_config "$CONFIG" "$home_real/config"; then
      echo "SECONDMATE_SYNC: secondmate $id: skipped: config inheritance failed"
    fi
  done < <(live_secondmate_meta_records "$STATE" "$FM_HOME/data/secondmates.md")
  [ -n "$FF_NUDGE_WINDOWS" ] && echo "NUDGE_SECONDMATES:$FF_NUDGE_WINDOWS"
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
  local meta id window harness backend target verdict out account_profile rollback_pending retry_profile retry_out
  local lifecycle_lock recheck spawn_message
  local -a resume_args retry_args
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
    verdict=$(fm_backend_agent_alive "$backend" "$target" "fm-$id" "$(fm_meta_get "$meta" tmux_session_target)" 2>/dev/null) || verdict="unknown"
    case "$harness" in
      claude|codex|opencode|pi|grok) ;;
      *) [ "$verdict" = dead ] && verdict=unknown ;;
    esac
    case "$verdict" in
      alive)
        echo "SECONDMATE_LIVENESS: secondmate $id: already-live"
        ;;
      dead)
        lifecycle_lock=$(fm_account_lifecycle_lock_acquire "$STATE" "$id" 2>/dev/null) || {
          echo "SECONDMATE_LIVENESS: secondmate $id: skipped: lifecycle recovery lock unavailable; respawn deferred"
          continue
        }
        if [ ! -f "$meta" ] || ! grep -q '^kind=secondmate$' "$meta" 2>/dev/null; then
          fm_account_lifecycle_lock_release "$lifecycle_lock" >/dev/null 2>&1 || true
          echo "SECONDMATE_LIVENESS: secondmate $id: skipped: task generation changed before recovery"
          continue
        fi
        window=$(fm_meta_get "$meta" window)
        if [ -z "$window" ]; then
          fm_account_lifecycle_lock_release "$lifecycle_lock" >/dev/null 2>&1 || true
          echo "SECONDMATE_LIVENESS: secondmate $id: skipped: task generation has no endpoint target"
          continue
        fi
        harness=$(fm_meta_get "$meta" harness)
        backend=$(fm_backend_of_meta "$meta")
        target=$(fm_backend_target_of_meta "$meta")
        [ -n "$target" ] || target="$window"
        recheck=$(fm_backend_agent_alive "$backend" "$target" "fm-$id" "$(fm_meta_get "$meta" tmux_session_target)" 2>/dev/null) || recheck=unknown
        case "$harness" in
          claude|codex|opencode|pi|grok) ;;
          *) [ "$recheck" = dead ] && recheck=unknown ;;
        esac
        case "$recheck" in
          alive)
            fm_account_lifecycle_lock_release "$lifecycle_lock" >/dev/null 2>&1 || true
            echo "SECONDMATE_LIVENESS: secondmate $id: already-live"
            continue
            ;;
          dead) ;;
          *)
            fm_account_lifecycle_lock_release "$lifecycle_lock" >/dev/null 2>&1 || true
            echo "SECONDMATE_LIVENESS: secondmate $id: skipped: liveness probe inconclusive (backend=$backend)"
            continue
            ;;
        esac
        account_profile=$(fm_meta_get "$meta" account_profile)
        rollback_pending=$(fm_meta_get "$meta" account_rollback_cleanup)
        if [ "$rollback_pending" != pending ] && [ -n "$account_profile" ] \
          && ! FM_ACCOUNT_LIFECYCLE_LOCK_HELD="$lifecycle_lock" "$FM_ROOT/bin/fm-account-session-sync.sh" "$id" --require >/dev/null 2>&1; then
          fm_account_lifecycle_lock_release "$lifecycle_lock" >/dev/null 2>&1 || true
          echo "SECONDMATE_LIVENESS: secondmate $id: respawn failed: managed account recovery has no verified provider-session mapping"
          continue
        fi
        fm_backend_kill "$backend" "$target" "$(fm_meta_get "$meta" zellij_tab_id)" "fm-$id" "$(fm_meta_get "$meta" tmux_session_target)" 2>/dev/null || true
        resume_args=()
        if [ "$rollback_pending" = pending ] || [ -n "$account_profile" ]; then
          resume_args+=(--resume-account)
        else
          fm_account_lifecycle_lock_release "$lifecycle_lock" >/dev/null 2>&1 || true
          echo "SECONDMATE_LIVENESS: secondmate $id: respawn deferred: unmanaged generation requires an explicit operator --no-account-routing decision"
          continue
        fi
        if out=$(FM_ACCOUNT_LIFECYCLE_LOCK_HELD="$lifecycle_lock" FM_SPAWN_NO_GUARD=1 \
          "$FM_ROOT/bin/fm-spawn.sh" "$id" --secondmate ${resume_args[@]+"${resume_args[@]}"} 2>&1); then
          spawn_message="SECONDMATE_LIVENESS: secondmate $id: respawned"
        elif [ "$rollback_pending" = pending ] && { [ ! -f "$meta" ] || [ "$(fm_meta_get "$meta" account_rollback_cleanup)" != pending ]; }; then
          if fm_account_lifecycle_lock_owned "$lifecycle_lock"; then
            fm_account_lifecycle_lock_release "$lifecycle_lock" >/dev/null 2>&1 || true
          fi
          lifecycle_lock=$(fm_account_lifecycle_lock_acquire "$STATE" "$id" 2>/dev/null) || {
            echo "SECONDMATE_LIVENESS: secondmate $id: rollback reconciled; respawn deferred: fresh lifecycle recovery lock unavailable"
            continue
          }
          retry_profile=
          [ ! -f "$meta" ] || retry_profile=$(fm_meta_get "$meta" account_profile)
          retry_args=()
          if [ -n "$retry_profile" ]; then
            retry_args+=(--resume-account)
          else
            fm_account_lifecycle_lock_release "$lifecycle_lock" >/dev/null 2>&1 || true
            echo "SECONDMATE_LIVENESS: secondmate $id: rollback reconciled; respawn deferred: restored unmanaged generation requires an explicit operator --no-account-routing decision"
            continue
          fi
          if [ -n "$retry_profile" ] \
            && ! FM_ACCOUNT_LIFECYCLE_LOCK_HELD="$lifecycle_lock" "$FM_ROOT/bin/fm-account-session-sync.sh" "$id" --require >/dev/null 2>&1; then
            fm_account_lifecycle_lock_release "$lifecycle_lock" >/dev/null 2>&1 || true
            echo "SECONDMATE_LIVENESS: secondmate $id: rollback reconciled; respawn deferred: restored managed generation has no verified provider-session mapping"
            continue
          fi
          if retry_out=$(FM_ACCOUNT_LIFECYCLE_LOCK_HELD="$lifecycle_lock" FM_SPAWN_NO_GUARD=1 \
            "$FM_ROOT/bin/fm-spawn.sh" "$id" --secondmate ${retry_args[@]+"${retry_args[@]}"} 2>&1); then
            spawn_message="SECONDMATE_LIVENESS: secondmate $id: rollback reconciled and respawned"
          else
            spawn_message="SECONDMATE_LIVENESS: secondmate $id: rollback reconciled; respawn deferred: $(first_line "$retry_out")"
          fi
        else
          spawn_message="SECONDMATE_LIVENESS: secondmate $id: respawn failed: $(first_line "$out")"
        fi
        if fm_account_lifecycle_lock_owned "$lifecycle_lock" \
          && ! fm_account_lifecycle_lock_release "$lifecycle_lock" >/dev/null 2>&1; then
          echo "SECONDMATE_LIVENESS: secondmate $id: skipped: lifecycle recovery lock release failed; inspect before retrying"
          continue
        fi
        echo "$spawn_message"
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
    python3) echo "brew install python  # or the platform's package manager" ;;
    cmux) echo "brew install --cask cmux  # or see https://cmux.com" ;;
    treehouse) echo "curl -fsSL https://kunchenguid.github.io/treehouse/install.sh | sh" ;;
    no-mistakes) echo "curl -fsSL https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh | sh" ;;
    gh-axi|chrome-devtools-axi) echo "npm install -g $1 && $1 setup hooks" ;;
    lavish-axi) echo "npm install -g '$FM_ROOT/tools/lavish' && lavish-axi configure-wake --home '$FM_HOME' --command '$FM_ROOT/bin/fm-lavish-wake.sh'" ;;
    tasks-axi|quota-axi) echo "npm install -g $1" ;;
    *) return 1 ;;
  esac
}

manual_install_url() {
  case "$1" in
    herdr) echo "https://herdr.dev" ;;
    nohup|perl) echo "https://github.com/ruby-dlee/firstmate/blob/main/docs/configuration.md#portable-process-control-prerequisites" ;;
    agent-fleet) echo "https://github.com/ruby-dlee/firstmate/blob/main/docs/configuration.md#agent-fleet-account-routing" ;;
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
COMMON_TOOLS="node python3 git gh perl no-mistakes gh-axi chrome-devtools-axi lavish-axi tasks-axi quota-axi"
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

lavish_axi_compatible() {
  local output
  command -v lavish-axi >/dev/null 2>&1 || return 1
  output=$(lavish-axi --version 2>/dev/null) || return 1
  # Empty-output stubs are used by hermetic bootstrap tests.
  # A real versioned binary must identify the firstmate-owned protocol.
  [ -z "$output" ] && return 0
  case "$output" in
    'lavish-axi 1.'*'(store-forward protocol 1)') return 0 ;;
    *) return 1 ;;
  esac
}

# Write CONTENT to DEST only when it differs, so re-running bootstrap does not
# churn mtimes or duplicate generated files (idempotence).
write_if_changed() {
  local dest=$1 content=$2
  [ -f "$dest" ] && [ "$(cat "$dest" 2>/dev/null)" = "$content" ] && return 0
  printf '%s\n' "$content" > "$dest"
}

# X mode (opt-in): when this home's .env carries a non-empty FMX_PAIRING_TOKEN,
# wire the relay poll into the EXISTING watcher check mechanism without touching
# fm-watch.sh or any other watcher-backbone file. Drops two idempotent,
# gitignored artifacts:
#   state/x-watch.check.sh - check shim that execs bin/fm-x-poll.sh each cycle
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
    rm -f "$shim" "$cadence" 2>/dev/null || true
    [ ! -e "$shim" ] && [ ! -e "$cadence" ]
  }

  x_mode_supervision_repair() {
    local out
    out=$("$SCRIPT_DIR/fm-supervision-instructions.sh" --repair-line 2>/dev/null) \
      || out='resume supervision according to the session-start operating block.'
    printf '%s\n' "$out"
  }

  if [ -z "$token" ]; then
    # Opt-out (or never opted in): drop any X artifacts; stay silent unless we
    # actually removed something.
    if [ -e "$shim" ] || [ -e "$cadence" ]; then
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
    if [ -e "$shim" ] || [ -e "$cadence" ]; then
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

  shim_body=$(cat <<EOF
#!/usr/bin/env bash
# Auto-generated by fm-bootstrap.sh - X mode connector poll shim.
# The watcher runs this each check cycle; output becomes a check: wake.
export FM_HOME=$(printf '%q' "$FM_HOME")
exec $(printf '%q' "$FM_ROOT/bin/fm-x-poll.sh")
EOF
)
  write_if_changed "$shim" "$shim_body" || { fmx_arm_failed; return 0; }
  chmod +x "$shim" 2>/dev/null || { fmx_arm_failed; return 0; }

  cadence_body=$(cat <<'EOF'
# Auto-generated by fm-bootstrap.sh - X mode watcher cadence.
# Source this before the active harness protocol starts a watcher process so
# fm-watch.sh polls the X check every 30s. Non-X instances have no such file and
# keep the default 300s cadence.
export FM_CHECK_INTERVAL=30
EOF
)
  write_if_changed "$cadence" "$cadence_body" || { fmx_arm_failed; return 0; }

  echo "FMX: X mode on - relay poll armed via state/x-watch.check.sh; 30s watcher cadence in config/x-mode.env"
}

BOOTSTRAP_JQ_REPORTED=0
ACCOUNT_ROUTING_MODE=off
ACCOUNT_ROUTING_NEEDS_DIRECT_TOOLS=0
ACCOUNT_ROUTING_NEEDS_AGENT_FLEET=0
CREW_DISPATCH_ROUTING_VALID=unknown

account_routing_preflight() {
  local mode mode_error
  if mode=$(fm_account_resolve_mode "$CONFIG" 0 0 2>&1); then
    ACCOUNT_ROUTING_MODE=$mode
  else
    mode_error=${mode#error: }
    echo "ACCOUNT_ROUTING: invalid routing policy - $mode_error"
  fi
  [ "$ACCOUNT_ROUTING_MODE" = off ] || ACCOUNT_ROUTING_NEEDS_DIRECT_TOOLS=1
  [ "$ACCOUNT_ROUTING_MODE" != enforce ] || ACCOUNT_ROUTING_NEEDS_AGENT_FLEET=1
}

account_routing_dependency_preflight() {
  local needs_direct=$ACCOUNT_ROUTING_NEEDS_DIRECT_TOOLS needs_agent_fleet=$ACCOUNT_ROUTING_NEEDS_AGENT_FLEET dispatch meta direct_perl
  dispatch="$CONFIG/crew-dispatch.json"
  if [ -f "$dispatch" ]; then
    if [ "$CREW_DISPATCH_ROUTING_VALID" = 1 ]; then
      jq -e '.. | objects | select(has("account_pool") or has("account_profile"))' "$dispatch" >/dev/null 2>&1 && needs_direct=1
    elif [ "$CREW_DISPATCH_ROUTING_VALID" = unknown ] \
      && grep -Eq '"account_(pool|profile)"[[:space:]]*:' "$dispatch" 2>/dev/null; then
      needs_direct=1
    fi
  fi
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    if grep -q '^account_home=.' "$meta" 2>/dev/null \
      && ! grep -qx 'kind=secondmate' "$meta" 2>/dev/null; then
      needs_direct=1
    fi
    if grep -q '^account_profile=' "$meta" 2>/dev/null \
      || grep -qx 'account_rollback_cleanup=pending' "$meta" 2>/dev/null; then
      needs_agent_fleet=1
    fi
  done
  if [ "$needs_direct" = 1 ] && ! command -v jq >/dev/null 2>&1; then
    echo "MISSING: jq (install: $(install_cmd jq))"
    BOOTSTRAP_JQ_REPORTED=1
  fi
  if [ "$needs_direct" = 1 ] && ! command -v herdr >/dev/null 2>&1; then
    missing_tool_diagnostic herdr
  fi
  direct_perl=/usr/bin/perl
  if [ "${FM_ACCOUNT_DIRECTORY_TEST_LAB:-}" = firstmate-account-directory-test-lab-v1 ] \
    && [ -n "${FM_ACCOUNT_DIRECTORY_PERL_BIN:-}" ]; then
    direct_perl=$FM_ACCOUNT_DIRECTORY_PERL_BIN
  fi
  if [ "$needs_direct" = 1 ] && [ ! -x "$direct_perl" ]; then
    missing_tool_diagnostic perl
  fi
  if [ "$needs_direct" = 1 ] || [ "$needs_agent_fleet" = 1 ]; then
    fm_account_fleet_bin >/dev/null 2>&1 || missing_tool_diagnostic agent-fleet
  fi
}

crew_dispatch_validate() {
  local file err
  file="$CONFIG/crew-dispatch.json"
  if [ ! -f "$file" ]; then
    CREW_DISPATCH_ROUTING_VALID=0
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    [ "$BOOTSTRAP_JQ_REPORTED" = 1 ] || echo "MISSING: jq (install: $(install_cmd jq))"
    return 0
  fi
  if ! jq -e . "$file" >/dev/null 2>&1; then
    CREW_DISPATCH_ROUTING_VALID=0
    echo "CREW_DISPATCH: invalid config/crew-dispatch.json - malformed JSON"
    return 0
  fi
  err=$(jq -r --arg routing_mode "$ACCOUNT_ROUTING_MODE" '
    def verified($h): ["claude","codex","opencode","pi","grok"] | index($h);
    def safe_account_id($v):
      ($v | type) == "string"
      and ($v | test("^[A-Za-z0-9][A-Za-z0-9._-]*$"))
      and ($v | contains("@") | not);
    def effort_ok($h; $e):
      if $e == null then true
      elif ($e | type) != "string" then false
      elif $h == "claude" then (["low","medium","high","xhigh","max"] | index($e))
      elif ($h == "codex" or $h == "pi") then (["low","medium","high","xhigh"] | index($e))
      elif $h == "grok" then (["low","medium","high"] | index($e))
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
    elif [(.rules // [])[]? | use_profiles(.use?)[]? | select(has("account_pool") and (safe_account_id(.account_pool) | not))] | length > 0 then "invalid account_pool"
    elif [(.rules // [])[]? | use_profiles(.use?)[]? | select(has("account_profile") and (safe_account_id(.account_profile) | not))] | length > 0 then "invalid account_profile"
    elif [(.rules // [])[]? | use_profiles(.use?)[]? | select(has("account_pool") and (.harness != "claude" and .harness != "codex"))] | length > 0 then "account_pool requires claude or codex harness"
    elif [(.rules // [])[]? | use_profiles(.use?)[]? | select(has("account_profile") and (.harness != "claude" and .harness != "codex"))] | length > 0 then "account_profile requires claude or codex harness"
    elif [(.rules // [])[]? | select(.select? == "quota-balanced") | select(([use_profiles(.use?)[] | has("account_pool")] | any) and ([use_profiles(.use?)[] | has("account_pool")] | all | not))] | length > 0 then "quota-balanced account_pool candidates must all carry account_pool"
    elif [(.rules // [])[]? | select(.select? == "quota-balanced") | use_profiles(.use?)[] | select(has("account_profile"))] | length > 0 then "quota-balanced candidates cannot carry account_profile"
    elif ($routing_mode == "enforce" and (([(.rules // [])[]? | select(.select? == "quota-balanced") | select([use_profiles(.use?)[] | has("account_pool")] | all | not)] | length) > 0)) then "enforced quota-balanced candidates must all carry account_pool"
    elif [(.rules // [])[]? | select(has("select") and ((.select? | type) != "string" or (.select | length) == 0))] | length > 0 then "select must be a non-empty string"
    elif [(.rules // [])[]? | .select? // empty | select(. != "quota-balanced")] | length > 0 then
      "unknown select: " + ([ (.rules // [])[]? | .select? // empty | select(. != "quota-balanced") ] | unique | join(", "))
    elif has("default") and (.default | type) != "object" then "default must be an object"
    elif has("default") and ((.default.harness? | type) != "string" or (.default.harness | length) == 0) then "default needs harness when present"
    elif has("default") and (.default | has("account_pool")) and (safe_account_id(.default.account_pool) | not) then "invalid default account_pool"
    elif has("default") and (.default | has("account_profile")) and (safe_account_id(.default.account_profile) | not) then "invalid default account_profile"
    elif has("default") and (.default | has("account_pool")) and (.default.harness != "claude" and .default.harness != "codex") then "default account_pool requires claude or codex harness"
    elif has("default") and (.default | has("account_profile")) and (.default.harness != "claude" and .default.harness != "codex") then "default account_profile requires claude or codex harness"
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
    CREW_DISPATCH_ROUTING_VALID=0
    echo "CREW_DISPATCH: invalid config/crew-dispatch.json - $err"
    return 0
  fi
  CREW_DISPATCH_ROUTING_VALID=1
  jq -r '
    def profile($p):
      ($p.harness | tostring)
      + (if ($p.model? != null) then "/" + ($p.model | tostring)
         elif ($p.effort? != null) then "/default"
         else "" end)
      + (if ($p.effort? != null) then "/" + ($p.effort | tostring) else "" end)
      + (if ($p.account_pool? != null) then "@" + ($p.account_pool | tostring) else "" end)
      + (if ($p.account_profile? != null) then "#" + ($p.account_profile | tostring) else "" end);
    def use_label($r):
      if ($r.use | type) == "array" then
        ((if ($r.select? != null) then ($r.select | tostring) else "first" end)
          + "[" + ([$r.use[] | profile(.)] | join(", ")) + "]")
      else profile($r.use)
      end;
    (["CREW_DISPATCH: active config/crew-dispatch.json"]
      + [(.rules // [])[]? | "  rule: " + (.when | tostring) + " -> " + use_label(.)]
      + (if (.default? | type) == "object" then ["  default: " + profile(.default)] else [] end))
    | .[]
  ' "$file"
}

if [ "${1:-}" = "install" ]; then
  shift
  [ $# -gt 0 ] || { echo "usage: fm-bootstrap.sh install <tool>..." >&2; exit 1; }
  for t in "$@"; do
    if [ "$t" = report-retention ]; then
      echo "installing report-retention LaunchAgent"
      "$SCRIPT_DIR/fm-report-retention.sh" install
      continue
    fi
    if [ "$t" = checkout-refresh ]; then
      echo "installing checkout-refresh LaunchAgent"
      "$SCRIPT_DIR/fm-checkout-refresh.sh" install
      continue
    fi
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
if command -v lavish-axi >/dev/null 2>&1 && ! lavish_axi_compatible; then
  echo "MISSING: lavish-axi (install: $(install_cmd lavish-axi))"
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
[ -n "$crew" ] && [ "$crew" != "default" ] && echo "CREW_HARNESS_OVERRIDE: $crew"
account_routing_preflight
crew_dispatch_validate
account_routing_dependency_preflight
if ! fm_backlog_backend_manual "$CONFIG" && fm_tasks_axi_compatible; then
  echo "TASKS_AXI: available"
fi
checkout_refresh_ensure
if [ "${FM_BOOTSTRAP_DETECT_ONLY:-0}" != 1 ]; then
  report_retention_ensure
  secondmate_sync
  secondmate_liveness_sweep
  x_mode_setup
  fleet_sync
fi
exit 0
