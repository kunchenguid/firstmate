#!/usr/bin/env bash
# fm-preflight-gate.sh - pre-dispatch admission gate for a ship spawn.
#
# Fleet engineering plan workstream 2 ("closes A + E", data/fleet-engineering-plan.html):
# root cause A is that preconditions get validated at the point of failure
# (push access discovered at push, quota discovered at spawn) instead of before
# commitment. This gate runs BEFORE fm-spawn.sh ever creates a worktree or
# launches a worker, and refuses admission unless all four of the following
# are true, each independently proven rather than assumed:
#
#   1. push-path       the resolved push target actually accepts a push from
#                       the authenticated GitHub identity: for no-mistakes
#                       mode with a 'no-mistakes' remote configured, that is
#                       the delivery remote 'no-mistakes status' reports (the
#                       'no-mistakes' git remote itself is a local gate repo,
#                       never the real upstream); otherwise it is a 'fork'
#                       remote if one is configured, else 'origin'.
#   2. delivery-path    the requested --mode can complete for THIS repo:
#                       no-mistakes requires the repo to be no-mistakes
#                       initialized; direct-PR requires that no committed
#                       pull_request-triggered workflow demands a
#                       no-mistakes-produced PR body (the exact way
#                       kunchenguid/firstmate rejects a hand-opened PR, see
#                       .github/workflows/no-mistakes-required.yml); local-only
#                       never pushes, so it always passes.
#   3. quota-headroom   quota-axi reports a FRESH, non-exhausted measurement
#                       for the resolved harness's provider. A harness quota-axi
#                       has no provider for (pi, pi-signed, opencode, muse, or a
#                       raw launch command) is not gated here - see "Scope" below.
#   4. concurrency      current host load average and available memory are
#                       inside a configured safe ceiling, so admission does not
#                       stack a task onto an already-saturated host.
#
# Usage: fm-preflight-gate.sh <project-dir> --mode <no-mistakes|direct-PR|local-only> --harness <name>
#
# Exit 0 and one "admitted: ..." line on stdout when all four pass.
# Exit FM_PREFLIGHT_REFUSE_EXIT (4) and one "refused [<check>]: <reason>" line
# per FAILED check on stderr otherwise - every check runs regardless of earlier
# failures, so a multi-precondition failure is reported completely, not
# one-at-a-time. Exit 2 is a usage error (bad args, project-dir not a git repo).
#
# Scope, stated plainly (claim only what is measured):
#   - Check 1 only verifies push access on a GitHub remote (github.com). A
#     project hosted elsewhere gets an explicit "cannot verify" refusal rather
#     than a silent pass, because this check has no other forge's permissions
#     API wired up yet.
#   - Check 2's direct-PR detection is a structural scan for a pull_request-
#     triggered workflow with a job that actually COMPARES a PR-body-derived
#     value against the marker no-mistakes itself writes ("git push
#     no-mistakes") - a line containing a comparison construct (grep, case,
#     [[ ]]/[ ], =~, ==, or the Actions contains()/startsWith() functions)
#     whose operands are a PR-body reference (the literal expression
#     "pull_request.body", or a variable previously assigned from it) and the
#     marker (the literal text, or a variable previously assigned it, as
#     firstmate's own workflow does via `marker='...git push no-mistakes...'`
#     then `grep -qF -- "$marker"`). Requiring an actual comparison, not mere
#     co-occurrence anywhere in the same job, keeps an unrelated step's PR-body
#     read (e.g. logging its length) plus a completely unconnected mention of
#     the marker in that same job's step name, env value, echo/printf text, or
#     heredoc body from being mistaken for enforcement. It catches the
#     no-mistakes-required convention (which is what actually blocked
#     direct-PR on firstmate's own repo); it does not evaluate arbitrary
#     branch-protection rules.
#   - Check 3 measures quota-axi's own reported state. AGENTS.md section 4
#     treats missing quota data as "disclosed uncertainty that keeps a
#     candidate eligible" when CHOOSING among harnesses at intake - a
#     different moment from this gate, which runs AFTER a harness is already
#     resolved. Here, a supported provider reporting stale/unmeasured/
#     exhausted data is exactly the dispatched-blind failure mode workstream 2
#     exists to catch, so it refuses. A harness quota-axi has no provider
#     concept for at all is a different situation (the tool does not cover
#     that axis, full stop) and is skipped rather than refused.
#   - Check 4 measures current host state only. It does not model a specific
#     task's marginal memory/CPU cost - there is no existing per-task
#     footprint data to model it from - so it refuses admission only when the
#     host is ALREADY at or over the configured ceiling. FM_PREFLIGHT_*_OVERRIDE
#     env vars exist solely so tests can force each branch deterministically
#     without actually starving the host; production dispatch never sets them.
#
# FM_PREFLIGHT_GATE_BYPASS=1 skips this script's own checks entirely when
# called through fm-spawn.sh's wiring (not through direct invocation of this
# script). tests/lib.sh exports it for the existing hermetic fm-spawn suites,
# which fake tmux/git but not gh-axi/quota-axi/no-mistakes - see that file for
# the precedent (bin/fm-gate-refuse-lib.sh's FM_GATE_REFUSE_BYPASS). This
# script's own tests (tests/fm-preflight-gate.test.sh) unset the bypass so the
# real refusal path stays covered.
set -u

FM_PREFLIGHT_REFUSE_EXIT=4
FM_PREFLIGHT_GH_CMD=${FM_PREFLIGHT_GH_CMD:-gh-axi}
FM_PREFLIGHT_QUOTA_CMD=${FM_PREFLIGHT_QUOTA_CMD:-quota-axi}
FM_PREFLIGHT_NM_CMD=${FM_PREFLIGHT_NM_CMD:-no-mistakes}
FM_PREFLIGHT_MIN_QUOTA_PERCENT=${FM_PREFLIGHT_MIN_QUOTA_PERCENT:-5}
FM_PREFLIGHT_MAX_LOAD_PER_CORE=${FM_PREFLIGHT_MAX_LOAD_PER_CORE:-1.5}
FM_PREFLIGHT_MIN_FREE_MEMORY_PERCENT=${FM_PREFLIGHT_MIN_FREE_MEMORY_PERCENT:-15}

usage() {
  echo "usage: fm-preflight-gate.sh <project-dir> --mode <no-mistakes|direct-PR|local-only> --harness <name>" >&2
}

PROJECT_DIR=
MODE=
HARNESS=
POS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$want_value" in
      mode) MODE=$a ;;
      harness) HARNESS=$a ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --mode) want_value=mode ;;
    --mode=*) MODE=${a#--mode=} ;;
    --harness) want_value=harness ;;
    --harness=*) HARNESS=${a#--harness=} ;;
    -h|--help) usage; exit 0 ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { usage; exit 2; }
PROJECT_DIR=${POS[0]:-}

[ -n "$PROJECT_DIR" ] || { usage; exit 2; }
case "$MODE" in
  no-mistakes|direct-PR|local-only) ;;
  *) echo "error: --mode must be one of no-mistakes, direct-PR, local-only (got '${MODE:-}')" >&2; usage; exit 2 ;;
esac
[ -n "$HARNESS" ] || { usage; exit 2; }
[ -d "$PROJECT_DIR" ] || { echo "error: no such directory: $PROJECT_DIR" >&2; exit 2; }
git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1 || {
  echo "error: $PROJECT_DIR is not a git repository" >&2
  exit 2
}

FM_PREFLIGHT_FAIL_REASON=

# --- check 1: push path -----------------------------------------------------

fm_preflight_github_owner_repo() {  # <remote-url> -> "<owner>/<repo>" on stdout
  local url=$1 rest
  case "$url" in
    git@github.com:*) rest=${url#git@github.com:} ;;
    ssh://git@github.com/*) rest=${url#ssh://git@github.com/} ;;
    https://github.com/*) rest=${url#https://github.com/} ;;
    http://github.com/*) rest=${url#http://github.com/} ;;
    *) return 1 ;;
  esac
  rest=${rest%.git}
  case "$rest" in
    */*) printf '%s\n' "$rest" ;;
    *) return 1 ;;
  esac
}

fm_preflight_check_push_path() {  # <project-dir> <mode>
  local dir=$1 mode=$2 remote_name target_url owner_repo perm nm_status nm_target
  if [ "$mode" = local-only ]; then
    return 0
  fi
  if [ "$mode" = no-mistakes ] && git -C "$dir" remote get-url no-mistakes >/dev/null 2>&1; then
    # The 'no-mistakes' git remote is always a local gate repo (see
    # bin/fm-home-seed.sh and tests/fm-secondmate-safety.test.sh), never the
    # real upstream, so checking IT for push permission would be meaningless.
    # 'no-mistakes status' reports the actual delivery destination it will
    # push to once its pipeline passes.
    nm_status=$(cd "$dir" && "$FM_PREFLIGHT_NM_CMD" status 2>&1) || true
    nm_target=$(printf '%s' "$nm_status" | sed -n 's/^[[:space:]]*remote:[[:space:]]*//p' | head -n1)
    if [ -z "$nm_target" ]; then
      FM_PREFLIGHT_FAIL_REASON="'$FM_PREFLIGHT_NM_CMD status' in $dir did not report its configured delivery remote; cannot verify push access to the real no-mistakes-managed target"
      return 1
    fi
    remote_name=no-mistakes
    target_url=$nm_target
  elif target_url=$(git -C "$dir" remote get-url fork 2>/dev/null); then
    remote_name=fork
  elif target_url=$(git -C "$dir" remote get-url origin 2>/dev/null); then
    remote_name=origin
  else
    FM_PREFLIGHT_FAIL_REASON="no 'origin' or 'fork' git remote is configured in $dir"
    return 1
  fi
  owner_repo=$(fm_preflight_github_owner_repo "$target_url") || {
    if [ "$remote_name" = no-mistakes ]; then
      FM_PREFLIGHT_FAIL_REASON="push path unverifiable: the no-mistakes-configured delivery remote ($target_url) is not a github.com URL this check can inspect"
    else
      FM_PREFLIGHT_FAIL_REASON="push path unverifiable: remote '$remote_name' ($target_url) is not a github.com URL this check can inspect"
    fi
    return 1
  }
  perm=$("$FM_PREFLIGHT_GH_CMD" api "repos/$owner_repo" --jq '.permissions.push' 2>/dev/null) || {
    FM_PREFLIGHT_FAIL_REASON="could not read push permission for $owner_repo via '$FM_PREFLIGHT_GH_CMD api' (auth failure, network, or repo not found)"
    return 1
  }
  case "$perm" in
    true) return 0 ;;
    false)
      if [ "$remote_name" = no-mistakes ]; then
        FM_PREFLIGHT_FAIL_REASON="no push access to the no-mistakes-configured delivery target ($owner_repo)"
      elif [ "$remote_name" = origin ]; then
        FM_PREFLIGHT_FAIL_REASON="no push access to origin ($owner_repo), and no 'fork' remote is configured as an alternate push target"
      else
        FM_PREFLIGHT_FAIL_REASON="no push access to the configured fork remote ($owner_repo)"
      fi
      return 1
      ;;
    *)
      FM_PREFLIGHT_FAIL_REASON="unexpected push-permission response for $owner_repo: '$perm'"
      return 1
      ;;
  esac
}

# --- check 2: delivery path --------------------------------------------------

fm_preflight_workflow_has_pull_request_trigger() {  # <file> -> 0 if 'on:' structurally declares the pull_request trigger
  local f=$1
  # A word-exact structural check of the 'on:' block, not a file-wide
  # substring search: "pull_request" would also match "pull_request_target"
  # (a different trigger) and the github.event.pull_request.body context
  # expression that ANY job reading the PR body contains, regardless of what
  # actually triggers the workflow.
  awk '
    BEGIN { in_on = 0; found = 0 }
    /^on:[[:space:]]*\[/ {
      line = $0
      sub(/^on:[[:space:]]*\[/, "", line)
      sub(/\].*/, "", line)
      n = split(line, arr, ",")
      for (i = 1; i <= n; i++) {
        tok = arr[i]
        gsub(/[[:space:]]/, "", tok)
        if (tok == "pull_request") found = 1
      }
      next
    }
    /^on:[[:space:]]*pull_request[[:space:]]*$/ { found = 1; next }
    /^on:[[:space:]]*$/ { in_on = 1; next }
    in_on && /^[^[:space:]]/ { in_on = 0 }
    in_on && /^[[:space:]]+pull_request:([[:space:]]|$)/ { found = 1 }
    END { if (found) print "MATCH" }
  ' "$f" 2>/dev/null | grep -q MATCH
}

fm_preflight_workflow_step_reads_no_mistakes_body() {  # <file> -> 0 if one job actually compares a PR-body value to the marker
  local f=$1
  awk -v sq="'" '
    function clear(arr) { for (k in arr) delete arr[k] }
    BEGIN { clear(body_vars); clear(marker_vars); in_jobs = 0 }
    /^jobs:[[:space:]]*$/ { in_jobs = 1; next }
    in_jobs && /^  [A-Za-z_][A-Za-z0-9_-]*:[[:space:]]*$/ {
      clear(body_vars); clear(marker_vars)
      next
    }
    {
      trimmed = $0
      sub(/^[[:space:]]+/, "", trimmed)
      if (trimmed ~ /^#/) next

      # Track a variable assigned FROM the PR body context expression (the
      # usual "env: NAME: ${{ github.event.pull_request.body }}" indirection)
      # so a later comparison line that only references the variable - not
      # the literal expression - still counts as a body-derived operand.
      if (trimmed ~ /^[A-Za-z_][A-Za-z0-9_]*:[[:space:]]*\$\{\{.*pull_request\.body.*\}\}/) {
        name = trimmed; sub(/:.*/, "", name); body_vars[name] = 1
      }

      # Track a shell variable assigned a string containing the literal
      # marker (the real no-mistakes-required.yml does this: marker="...git
      # push no-mistakes..." then later compares against $marker), so the
      # comparison line does not need to spell the marker out itself.
      if (trimmed ~ /^[A-Za-z_][A-Za-z0-9_]*=.*git push no-mistakes/) {
        name = trimmed; sub(/=.*/, "", name); marker_vars[name] = 1
      }

      # A comparison construct is required on the SAME line as both
      # operands: a bare mention of the body or the marker anywhere in the
      # job (a step name, an unrelated env value, an echo/printf string, a
      # heredoc body) proves nothing about whether they are ever checked
      # against each other. The keyword itself must be real code too, not
      # incidental prose inside a quoted string (e.g. an echo message that
      # happens to say "grep") or part of a longer identifier - so blank out
      # quoted string contents and require a word-bounded match before
      # treating the line as a comparison. Operands (checked below) may still
      # be literal quoted text, so that check still reads the full line.
      code = trimmed
      gsub(/"[^"]*"/, "", code)
      gsub(sq "[^" sq "]*" sq, "", code)
      if (code !~ /(^|[^A-Za-z0-9_])(grep|case)([^A-Za-z0-9_]|$)/ \
          && code !~ /\[\[?[[:space:]]/ \
          && code !~ /=~|==|contains\(|startsWith\(/) next

      has_body = (trimmed ~ /pull_request\.body/)
      if (!has_body) {
        for (v in body_vars) {
          if (index(trimmed, "$" v) > 0 || index(trimmed, "${" v) > 0) { has_body = 1; break }
        }
      }
      has_marker = (trimmed ~ /git push no-mistakes/)
      if (!has_marker) {
        for (v in marker_vars) {
          if (index(trimmed, "$" v) > 0 || index(trimmed, "${" v) > 0) { has_marker = 1; break }
        }
      }
      if (has_body && has_marker) { print "MATCH"; exit }
    }
  ' "$f" 2>/dev/null | grep -q MATCH
}

fm_preflight_check_delivery_path() {  # <project-dir> <mode>
  local dir=$1 mode=$2 out f
  case "$mode" in
    local-only)
      return 0
      ;;
    no-mistakes)
      out=$(cd "$dir" && "$FM_PREFLIGHT_NM_CMD" status 2>&1) || true
      if printf '%s' "$out" | grep -qi 'not initialized'; then
        FM_PREFLIGHT_FAIL_REASON="no-mistakes reports $dir is not initialized (run 'no-mistakes init' there first)"
        return 1
      fi
      if ! printf '%s' "$out" | grep -q 'gate:'; then
        FM_PREFLIGHT_FAIL_REASON="'$FM_PREFLIGHT_NM_CMD status' in $dir did not report a gate; output: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
        return 1
      fi
      return 0
      ;;
    direct-PR)
      for f in "$dir"/.github/workflows/*.yml "$dir"/.github/workflows/*.yaml; do
        [ -f "$f" ] || continue
        # Require a pull_request trigger AND a single job that both reads
        # the PR body and checks it for the no-mistakes marker - not just
        # both phrases appearing anywhere in the file, which would conflate
        # an unrelated job's PR-body read with a different unrelated job's
        # incidental mention of "git push no-mistakes".
        if fm_preflight_workflow_has_pull_request_trigger "$f" \
          && fm_preflight_workflow_step_reads_no_mistakes_body "$f"; then
          FM_PREFLIGHT_FAIL_REASON="$(basename "$f") requires a no-mistakes-produced PR body (a step checks pull_request.body for the 'git push no-mistakes' marker on a pull_request trigger); a hand-opened direct-PR cannot satisfy it"
          return 1
        fi
      done
      return 0
      ;;
  esac
}

# --- check 3: quota headroom -------------------------------------------------

fm_preflight_harness_quota_provider() {  # <harness> -> provider name on stdout
  case "$1" in
    claude) echo claude ;;
    codex) echo codex ;;
    grok) echo grok ;;
    kimi) echo kimi ;;
    cursor) echo cursor ;;
    *) return 1 ;;
  esac
}

fm_preflight_check_quota() {  # <harness>
  local harness=$1 provider json state_status err percent runway threshold whole
  provider=$(fm_preflight_harness_quota_provider "$harness") || {
    # Not a refusal: quota-axi has no provider concept for this harness at
    # all (pi, pi-signed, opencode, muse, a raw launch command). See "Scope"
    # in the header comment.
    return 0
  }
  command -v jq >/dev/null 2>&1 || {
    FM_PREFLIGHT_FAIL_REASON="jq is required to parse '$FM_PREFLIGHT_QUOTA_CMD --json' output"
    return 1
  }
  json=$("$FM_PREFLIGHT_QUOTA_CMD" --json 2>/dev/null) || {
    FM_PREFLIGHT_FAIL_REASON="'$FM_PREFLIGHT_QUOTA_CMD --json' failed to run"
    return 1
  }
  state_status=$(printf '%s' "$json" | jq -r --arg p "$provider" '(.providers[] | select(.provider==$p) | .state.status) // "missing"')
  if [ "$state_status" != fresh ]; then
    err=$(printf '%s' "$json" | jq -r --arg p "$provider" '(.providers[] | select(.provider==$p) | (.state.error // .state.reason // "no measurement available"))')
    FM_PREFLIGHT_FAIL_REASON="quota headroom for '$provider' is not measured (state: ${state_status:-missing}, $err); this needs the one-time 'quota-axi --allow-keychain-prompt' approval or completed sign-in, not an assumption that it is fine"
    return 1
  fi
  percent=$(printf '%s' "$json" | jq -r --arg p "$provider" '[(.providers[] | select(.provider==$p) | .quotaSemantics.effectiveAvailability[]? | select(.scope=="all_models") | .effectivePercentRemaining)][0] // empty')
  runway=$(printf '%s' "$json" | jq -r --arg p "$provider" '[(.providers[] | select(.provider==$p) | .quotaSemantics.effectiveAvailability[]? | select(.scope=="all_models") | .runway.status)][0] // empty')
  if [ -z "$percent" ]; then
    FM_PREFLIGHT_FAIL_REASON="'$FM_PREFLIGHT_QUOTA_CMD' reports a fresh state for '$provider' but no effective-availability percentage; refusing rather than assuming headroom"
    return 1
  fi
  threshold=$FM_PREFLIGHT_MIN_QUOTA_PERCENT
  whole=${percent%%.*}
  if [ "$runway" = exhausted_now ] || { [ -n "$whole" ] && [ "$whole" -le "$threshold" ] 2>/dev/null; }; then
    FM_PREFLIGHT_FAIL_REASON="quota headroom for '$provider' measured at ${percent}% (runway: ${runway:-unknown}), at or below the ${threshold}% floor"
    return 1
  fi
  return 0
}

# --- check 4: concurrency / host capacity ------------------------------------

fm_preflight_host_cores() {
  if [ -n "${FM_PREFLIGHT_CORES_OVERRIDE:-}" ]; then
    printf '%s\n' "$FM_PREFLIGHT_CORES_OVERRIDE"
  elif [ -r /proc/cpuinfo ]; then
    grep -c ^processor /proc/cpuinfo
  elif command -v sysctl >/dev/null 2>&1; then
    sysctl -n hw.ncpu 2>/dev/null || echo 1
  else
    echo 1
  fi
}

fm_preflight_load1() {
  if [ -n "${FM_PREFLIGHT_LOAD_OVERRIDE:-}" ]; then
    printf '%s\n' "$FM_PREFLIGHT_LOAD_OVERRIDE"
  elif [ -r /proc/loadavg ]; then
    awk '{print $1}' /proc/loadavg
  elif command -v sysctl >/dev/null 2>&1; then
    sysctl -n vm.loadavg 2>/dev/null | awk '{gsub(/[{}]/, ""); print $1}'
  else
    echo 0
  fi
}

fm_preflight_mem_free_percent() {
  if [ -n "${FM_PREFLIGHT_MEM_FREE_PERCENT_OVERRIDE:-}" ]; then
    printf '%s\n' "$FM_PREFLIGHT_MEM_FREE_PERCENT_OVERRIDE"
  elif [ -r /proc/meminfo ]; then
    awk '/^MemAvailable:/{a=$2} /^MemTotal:/{t=$2} END{if (t>0) printf "%.0f", (a/t)*100}' /proc/meminfo
  elif command -v vm_stat >/dev/null 2>&1 && command -v sysctl >/dev/null 2>&1; then
    local total pagesize stats free inactive spec purge
    total=$(sysctl -n hw.memsize 2>/dev/null) || return 0
    stats=$(vm_stat 2>/dev/null) || return 0
    pagesize=$(printf '%s\n' "$stats" | sed -n 's/.*page size of \([0-9][0-9]*\) bytes.*/\1/p')
    free=$(printf '%s\n' "$stats" | awk '/^Pages free:/{gsub(/[.]/, "", $3); print $3}')
    inactive=$(printf '%s\n' "$stats" | awk '/^Pages inactive:/{gsub(/[.]/, "", $3); print $3}')
    spec=$(printf '%s\n' "$stats" | awk '/^Pages speculative:/{gsub(/[.]/, "", $3); print $3}')
    purge=$(printf '%s\n' "$stats" | awk '/^Pages purgeable:/{gsub(/[.]/, "", $3); print $3}')
    if [ -n "$total" ] && [ -n "$pagesize" ] && [ -n "$free" ]; then
      awk -v f="$free" -v i="${inactive:-0}" -v s="${spec:-0}" -v p="${purge:-0}" -v ps="$pagesize" -v t="$total" \
        'BEGIN { avail=(f+i+s+p)*ps; if (t>0) printf "%.0f", (avail/t)*100 }'
    fi
  fi
}

fm_preflight_check_concurrency() {
  local cores load1 memfree ceiling_load mem_floor ceiling_abs
  cores=$(fm_preflight_host_cores)
  load1=$(fm_preflight_load1)
  memfree=$(fm_preflight_mem_free_percent)
  ceiling_load=$FM_PREFLIGHT_MAX_LOAD_PER_CORE
  mem_floor=$FM_PREFLIGHT_MIN_FREE_MEMORY_PERCENT
  if [ -z "$memfree" ] || [ -z "$load1" ] || [ -z "$cores" ]; then
    FM_PREFLIGHT_FAIL_REASON="host load/memory could not be measured; refusing rather than assuming headroom"
    return 1
  fi
  ceiling_abs=$(awk -v c="$cores" -v m="$ceiling_load" 'BEGIN { printf "%.2f", c * m }')
  if awk -v l="$load1" -v ceiling="$ceiling_abs" 'BEGIN { exit !(l > ceiling) }'; then
    FM_PREFLIGHT_FAIL_REASON="host 1-minute load average ($load1) exceeds the safe ceiling of $ceiling_abs ($cores cores x ${ceiling_load})"
    return 1
  fi
  if [ "$memfree" -lt "$mem_floor" ] 2>/dev/null; then
    FM_PREFLIGHT_FAIL_REASON="host available memory (${memfree}%) is below the safe floor of ${mem_floor}%"
    return 1
  fi
  return 0
}

# --- run all four, report every failure --------------------------------------

FAILED=0

if ! fm_preflight_check_push_path "$PROJECT_DIR" "$MODE"; then
  echo "error: preflight refused [push-path]: $FM_PREFLIGHT_FAIL_REASON" >&2
  FAILED=1
fi

if ! fm_preflight_check_delivery_path "$PROJECT_DIR" "$MODE"; then
  echo "error: preflight refused [delivery-path]: $FM_PREFLIGHT_FAIL_REASON" >&2
  FAILED=1
fi

if ! fm_preflight_check_quota "$HARNESS"; then
  echo "error: preflight refused [quota-headroom]: $FM_PREFLIGHT_FAIL_REASON" >&2
  FAILED=1
fi

if ! fm_preflight_check_concurrency; then
  echo "error: preflight refused [concurrency]: $FM_PREFLIGHT_FAIL_REASON" >&2
  FAILED=1
fi

if [ "$FAILED" -eq 1 ]; then
  exit "$FM_PREFLIGHT_REFUSE_EXIT"
fi

echo "admitted: push-path=ok delivery-path=ok quota-headroom=ok concurrency=ok mode=$MODE harness=$HARNESS"
exit 0
